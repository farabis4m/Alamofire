//
//  Request.swift
//
//  Copyright (c) 2014-2016 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// A type that can inspect and optionally adapt a `URLRequest` in some manner if necessary.
public protocol RequestAdapter {
    /// Inspects and adapts the specified `URLRequest` in some manner if necessary and returns the result.
    ///
    /// - parameter urlRequest: The URL request to adapt.
    ///
    /// - throws: An `Error` if the adaptation encounters an error.
    ///
    /// - returns: The adapted `URLRequest`.
    func adapt(_ urlRequest: URLRequest) throws -> URLRequest
}

// MARK: -

/// A closure executed when the `RequestRetrier` determines whether a `Request` should be retried or not.
public typealias RequestRetryCompletion = (_ shouldRetry: Bool, _ timeDelay: TimeInterval) -> Void

/// A type that determines whether a request should be retried after being executed by the specified session manager
/// and encountering an error.
public protocol RequestRetrier {
    /// Determines whether the `Request` should be retried by calling the `completion` closure.
    ///
    /// This operation is fully asychronous. Any amount of time can be taken to determine whether the request needs
    /// to be retried. The one requirement is that the completion closure is called to ensure the request is properly
    /// cleaned up after.
    ///
    /// - parameter manager:    The session manager the request was executed on.
    /// - parameter request:    The request that failed due to the encountered error.
    /// - parameter error:      The error encountered when executing the request.
    /// - parameter completion: The completion closure to be executed when retry decision has been determined.
    func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion)
}

// MARK: -

protocol TaskConvertible {
    func task(session: URLSession, adapter: RequestAdapter?, queue: DispatchQueue) throws -> URLSessionTask
}

/// A dictionary of headers to apply to a `URLRequest`.
public typealias HTTPHeaders = [String: String]

// MARK: -

/// Responsible for sending a request and receiving the response and associated data from the server, as well as
/// managing its underlying `URLSessionTask`.
open class Request {

    // MARK: Helper Types

    /// A closure executed when monitoring upload or download progress of a request.
    public typealias ProgressHandler = (Progress) -> Void

    enum RequestTask {
        case data(TaskConvertible?, URLSessionTask?)
        case download(TaskConvertible?, URLSessionTask?)
        case upload(TaskConvertible?, URLSessionTask?)
        case stream(TaskConvertible?, URLSessionTask?)
    }

    // MARK: Properties

    /// The delegate for the underlying task.
    open internal(set) var delegate: TaskDelegate {
        get {
            taskDelegateLock.lock() ; defer { taskDelegateLock.unlock() }
            return taskDelegate
        }
        set {
            taskDelegateLock.lock() ; defer { taskDelegateLock.unlock() }
            taskDelegate = newValue
        }
    }

    /// The underlying task.
    open var task: URLSessionTask? { return delegate.task }

    /// The session belonging to the underlying task.
    open let session: URLSession

    /// The request sent or to be sent to the server.
    open var request: URLRequest? { return task?.originalRequest }

    /// The response received from the server, if any.
    open var response: HTTPURLResponse? { return task?.response as? HTTPURLResponse }

    /// The number of times the request has been retried.
    open internal(set) var retryCount: UInt = 0

    var originalTask: TaskConvertible?

    var startTime: CFAbsoluteTime?
    var endTime: CFAbsoluteTime?

    var validations: [() -> Void] = []
    
//    internal var error: ((Error) -> Void)?

    private var taskDelegate: TaskDelegate
    private var taskDelegateLock = NSLock()

    // MARK: Lifecycle

    init(session: URLSession, requestTask: RequestTask, error: Error? = nil) {
        self.session = session

        switch requestTask {
        case .data(let originalTask, let task):
            taskDelegate = DataTaskDelegate(task: task)
            self.originalTask = originalTask
        case .download(let originalTask, let task):
            taskDelegate = DownloadTaskDelegate(task: task)
            self.originalTask = originalTask
        case .upload(let originalTask, let task):
            taskDelegate = UploadTaskDelegate(task: task)
            self.originalTask = originalTask
        case .stream(let originalTask, let task):
            taskDelegate = TaskDelegate(task: task)
            self.originalTask = originalTask
        }

        delegate.error = error
        delegate.queue.addOperation { self.endTime = CFAbsoluteTimeGetCurrent() }
    }

    // MARK: Authentication

    /// Associates an HTTP Basic credential with the request.
    ///
    /// - parameter user:        The user.
    /// - parameter password:    The password.
    /// - parameter persistence: The URL credential persistence. `.ForSession` by default.
    ///
    /// - returns: The request.
    @discardableResult
    open func authenticate(
        user: String,
        password: String,
        persistence: URLCredential.Persistence = .forSession)
        -> Self
    {
        let credential = URLCredential(user: user, password: password, persistence: persistence)
        return authenticate(usingCredential: credential)
    }

    /// Associates a specified credential with the request.
    ///
    /// - parameter credential: The credential.
    ///
    /// - returns: The request.
    @discardableResult
    open func authenticate(usingCredential credential: URLCredential) -> Self {
        delegate.credential = credential
        return self
    }

    /// Returns a base64 encoded basic authentication credential as an authorization header tuple.
    ///
    /// - parameter user:     The user.
    /// - parameter password: The password.
    ///
    /// - returns: A tuple with Authorization header and credential value if encoding succeeds, `nil` otherwise.
    open static func authorizationHeader(user: String, password: String) -> (key: String, value: String)? {
        guard let data = "\(user):\(password)".data(using: .utf8) else { return nil }

        let credential = data.base64EncodedString(options: [])

        return (key: "Authorization", value: "Basic \(credential)")
    }

    // MARK: State

    /// Resumes the request.
    open func resume() {
        guard let task = task else { delegate.queue.isSuspended = false ; return }
        
        if startTime == nil { startTime = CFAbsoluteTimeGetCurrent() }
        
        task.resume()
        
        NotificationCenter.default.post(name: Notification.Name.Task.DidResume, object: self, userInfo: [Notification.Key.Task: task])
    }

    /// Suspends the request.
    open func suspend() {
        guard let task = task else { return }

        task.suspend()

        NotificationCenter.default.post(name: Notification.Name.Task.DidSuspend, object: self, userInfo: [Notification.Key.Task: task])
    }

    /// Cancels the request.
    open func cancel() {
        guard let task = task else { return }

        task.cancel()

        NotificationCenter.default.post(name: Notification.Name.Task.DidCancel,object: self, userInfo: [Notification.Key.Task: task])
    }
}





