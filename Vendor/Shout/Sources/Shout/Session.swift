//
//  Session.swift
//  Shout
//
//  Created by Jake Heiser on 3/4/18.
//

import Foundation
import CSSH
import Socket

/// Direct bindings to libssh2_session
class Session {
    
    private static let initResult = libssh2_init(0)
    
    private let cSession: OpaquePointer
    private var agent: Agent?
    
    var blocking: Int32 {
        get {
            return libssh2_session_get_blocking(cSession)
        }
        set(newValue) {
            libssh2_session_set_blocking(cSession, newValue)
        }
    }

    /// Milliseconds a blocking libssh2 call may wait before returning
    /// LIBSSH2_ERROR_TIMEOUT. 0 (default) = wait forever. Used to keep a stalled
    /// network read from hanging the SSH queue indefinitely.
    var timeout: Int {
        get { libssh2_session_get_timeout(cSession) }
        set { libssh2_session_set_timeout(cSession, newValue) }
    }

    init() throws {
        guard Session.initResult == 0 else {
            throw SSHError.genericError("libssh2_init failed")
        }
        
        guard let cSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.genericError("libssh2_session_init failed")
        }
        
        self.cSession = cSession
    }
    
    func handshake(over socket: Socket) throws {
        let code = libssh2_session_handshake(cSession, socket.socketfd)
        try SSHError.check(code: code, session: cSession)
    }
    
    func authenticate(username: String, privateKey: String, publicKey: String, passphrase: String?) throws {
        let code = libssh2_userauth_publickey_fromfile_ex(cSession,
                                                          username,
                                                          UInt32(username.count),
                                                          publicKey,
                                                          privateKey,
                                                          passphrase)
        try SSHError.check(code: code, session: cSession)
    }
    
    func authenticate(username: String, password: String) throws {
        let code = libssh2_userauth_password_ex(cSession,
                                                username,
                                                UInt32(username.count),
                                                password,
                                                UInt32(password.count),
                                                nil)
        try SSHError.check(code: code, session: cSession)
    }

    /// Authenticate with a private key held in memory (PEM/OpenSSH text).
    /// The public key is left NULL so libssh2 (OpenSSL backend) derives it from
    /// the private key — so no `.pub` file and no on-disk temp file are needed.
    /// Vital on iOS, where the sandbox has no `~/.ssh` and Shout's file-based
    /// path falls through to a TTY `getpass()` prompt that can't work in a GUI.
    func authenticate(username: String, privateKeyData: String, passphrase: String?) throws {
        let code = libssh2_userauth_publickey_frommemory(cSession,
                                                         username,
                                                         username.utf8.count,
                                                         nil,
                                                         0,
                                                         privateKeyData,
                                                         privateKeyData.utf8.count,
                                                         passphrase)
        try SSHError.check(code: code, session: cSession)
    }
    
    func openSftp() throws -> SFTP  {
        return try SFTP(session: self, cSession: cSession)
    }
    
    func openCommandChannel() throws -> Channel {
        return try Channel.createForCommand(cSession: cSession)
    }

    func openSCPChannel(fileSize: Int64, remotePath: String, permissions: FilePermissions) throws -> Channel {
        return try Channel.createForSCP(cSession: cSession, fileSize: fileSize, remotePath: remotePath, permissions: permissions)
    }
    
    func openAgent() throws -> Agent {
        if let agent = agent {
            return agent
        }
        let newAgent = try Agent(cSession: cSession)
        agent = newAgent
        return newAgent
    }
    
    deinit {
        libssh2_session_free(cSession)
    }
    
}
