//
//  IndexDB.swift
//  refactord
//
//  Created by John Holdsworth on 29/01/2016.
//  Copyright © 2015 John Holdsworth. All rights reserved.
//
//  $Id: //depot/Refactorator/refactord/IndexDB.swift#25 $
//
//  Repo: https://github.com/johnno1962/Refactorator
//
//

import Foundation

class IndexDB {

    private var handle: COpaquePointer = nil

    var error: String {
        return String.fromCString( sqlite3_errmsg( handle ) ) ?? "DB ERROR"
    }

    let filenames: IndexStrings
    let directories: IndexStrings
    let resolutions: IndexStrings
    var kinds = [Int:String]()

    init?( dbPath: String ) {
        filenames = IndexStrings( path: dbPath+".strings-file" )
        directories = IndexStrings( path: dbPath+".strings-dir" )
        resolutions = IndexStrings( path: dbPath+".strings-res" )
        guard sqlite3_open_v2( dbPath, &handle, SQLITE_OPEN_READONLY, nil ) == SQLITE_OK else {
            xcode.error( "Unable to open Index DB at \(dbPath): \(error)" )
            return nil
        }
        guard select( "select id, identifier from kind", ids: [], row: {
            (stmt) in
            let id = Int(sqlite3_column_int64(stmt, 0))
            let kind = UnsafePointer<CChar>(sqlite3_column_text(stmt, 1))
            self.kinds[id] = String.fromCString( kind )
        } ) else {
            xcode.error( "Could not select kinds" )
            return nil
        }
    }

    deinit {
        if handle != nil {
            sqlite3_close( handle )
        }
    }

    func select( sql: String, ids: [Int], row: (stmt: COpaquePointer) -> () ) -> Bool {
        var stmt: COpaquePointer = nil
        guard sqlite3_prepare_v2( handle, sql, -1, &stmt, nil ) == SQLITE_OK else { return false }
        defer {
            sqlite3_finalize(stmt)
        }

        for p in 0..<ids.count {
            guard sqlite3_bind_int64(stmt, Int32(p+1), Int64(ids[p])) == SQLITE_OK else { return false }
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            row( stmt: stmt )
        }

        return true
    }

    func usrInFile( filePath: String, line: Int, col: Int ) -> String? {

        let url = NSURL( fileURLWithPath: filePath )
        guard let directory = url.URLByDeletingLastPathComponent?.path, fileName = url.lastPathComponent else {
            xcode.error( "Could not parse filePath: \(filePath)" )
            return nil
        }
        let filename = fileName.lowercaseString

        var usr: String? = nil

        if let fileid = filenames[filename], fileID = filenames[fileName],  dirID = directories[directory] {

            let referenceSQL = "select r.resolution from file f" +
                " inner join group_ g on (f.id = g.file)" +
                " inner join reference r on (g.id = r.group_)" +
                " where f.lowercaseFilename = ? and f.filename = ? and f.directory = ?" +
                " and r.lineNumber = ? and r.column = ?"
            let symbolSQL = "select s.resolution from file f" +
                " inner join group_ g on (f.id = g.file)" +
                " inner join symbol s on (g.id = s.group_)" +
                " where f.lowercaseFilename = ? and f.filename = ? and f.directory = ?" +
                " and s.lineNumber = ? and s.column = ?"

            guard select( referenceSQL + " union " + symbolSQL,
                    ids: [fileid, fileID, dirID, line, col, fileid, fileID, dirID, line, col], row: {
                (stmt) in
                let usrID = Int(sqlite3_column_int64(stmt, 0))
                if let utmp = self.resolutions[usrID] where usr == nil ||
                        utmp.utf16.count < usr!.utf16.count {
                    usr = utmp
                }
                print( "Refactorator: Found USR #\(usrID) -- \(usr)" )
            } ) else {
                xcode.error( "USR prepare error: \(error)" )
                return nil
            }
        }

        return usr
    }

    func entitiesForUSR( usr: String, oldValue: String ) -> [Entity] {
        var entities = [Entity]()

        if let resID = resolutions[usr] {

            let referenceSQL = "select f.filename, f.directory, r.lineNumber, r.column, r.kind, 0" +
                " from reference r " +
                " inner join group_ g on (g.id = r.group_)" +
                " inner join file f on (f.id = g.file)" +
                " where r.resolution = ?"
            let symbolSQL = "select f.filename, f.directory, s.lineNumber, s.column, s.kind, 1" +
                " from symbol s " +
                " inner join group_ g on (g.id = s.group_)" +
                " inner join file f on (f.id = g.file)" +
                " where s.resolution = ?"

            guard select( referenceSQL + " union " + symbolSQL, ids: [resID, resID], row: {
                (stmt) in

                let fileID = Int(sqlite3_column_int64(stmt, 0))
                let dirID = Int(sqlite3_column_int64(stmt, 1))
                let line = Int(sqlite3_column_int64(stmt, 2))
                let col = Int(sqlite3_column_int64(stmt, 3))
                let kind = Int(sqlite3_column_int64(stmt, 4))
                let decl = sqlite3_column_int64(stmt, 5) != 0

                if line != 0 {
                    if let file = self.filenames[fileID], dir = self.directories[dirID] {
                        entities.append( Entity( file: dir+"/"+file, line: line, col: col, kind: self.kinds[kind], decl: decl ) )
                    }
                    else {
                        xcode.log( "Could not look up fileID: \(fileID) or dirID: \(dirID)" )
                    }
                }

            } ) else {
                xcode.error( "Entities prepare error \(error)" ); return entities
            }
        }

        return entities
    }

}
