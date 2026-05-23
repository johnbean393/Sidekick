//
//  main.swift
//  llama-server-watchdog
//
//  Created by Bean John on 10/9/24.
//

import Darwin
import Foundation

/// Function for logging, used for debug
func log(_ line: String) {
	print("[watchdog]", line)
}

/// Function to terminate the server process. Sends SIGTERM, waits briefly
/// for graceful exit, then escalates to SIGKILL so a wedged `llama-server`
/// is guaranteed to release its memory.
func terminateServerProcess(pid: Int32, reason: String) {
	log("\(reason); terminating the server process with PID \(pid).")
	if kill(pid, 0) == 0 {
		_ = kill(pid, SIGTERM)
		let deadline = Date().addingTimeInterval(2.0)
		while Date() < deadline && kill(pid, 0) == 0 {
			Thread.sleep(forTimeInterval: 0.05)
		}
		if kill(pid, 0) == 0 {
			log("PID \(pid) did not exit after SIGTERM; escalating to SIGKILL.")
			_ = kill(pid, SIGKILL)
		}
	}
	log("Terminated server, exiting")
	exit(0)
}

/// Wait for the host app to disappear and then kill the server.
///
/// The host app keeps the heartbeat pipe open and periodically writes a byte
/// to it. We block on `poll()` so we react immediately when the pipe is
/// closed (kernel does this when the host process crashes or is SIGKILLed)
/// and fall back to a 30 s liveness timeout for the case where the host is
/// alive but has stopped heartbeating.
func checkHeartbeat(serverProcessPID: Int32) {
	let fd = FileHandle.standardInput.fileDescriptor
	let heartbeatTimeoutMs: Int32 = 30_000
	var buffer = [UInt8](repeating: 0, count: 64)
	while true {
		var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
		let result = withUnsafeMutablePointer(to: &pfd) { ptr in
			poll(ptr, 1, heartbeatTimeoutMs)
		}
		if result < 0 {
			if errno == EINTR { continue }
			terminateServerProcess(
				pid: serverProcessPID,
				reason: "poll() failed (errno=\(errno))"
			)
		}
		if result == 0 {
			terminateServerProcess(
				pid: serverProcessPID,
				reason: "No heartbeat from host app for \(heartbeatTimeoutMs / 1000)s"
			)
		}
		// `POLLHUP` is set when the write end of the pipe is closed (the
		// host crashed / was killed). React immediately.
		if pfd.revents & Int16(POLLHUP) != 0 {
			terminateServerProcess(
				pid: serverProcessPID,
				reason: "Host app pipe hung up (crash or SIGKILL)"
			)
		}
		// Drain the heartbeat byte(s).
		let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
			read(fd, ptr.baseAddress, ptr.count)
		}
		if bytesRead == 0 {
			terminateServerProcess(
				pid: serverProcessPID,
				reason: "Host app pipe closed (EOF)"
			)
		}
		if bytesRead < 0 && errno != EAGAIN && errno != EINTR {
			terminateServerProcess(
				pid: serverProcessPID,
				reason: "read() error (errno=\(errno))"
			)
		}
	}
}

/// Function to start the watchdog
func startWatchdog() {
	
	guard CommandLine.arguments.count == 2 else {
		print("Usage: server-watchdog <pid_to_kill>")
		return
	}
	
	guard let serverProcessPID = Int32(CommandLine.arguments[1]) else {
		log("Error: Invalid server process PID.")
		return
	}
	
	log("Watchdog process started.")
	checkHeartbeat(serverProcessPID: serverProcessPID)
}

/// Call the function to start the watchdog process
startWatchdog()
