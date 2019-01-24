//
//  TRDownloadTask.swift
//  Tiercel
//
//  Created by Daniels on 2018/3/16.
//  Copyright © 2018年 Daniels. All rights reserved.
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

import UIKit

public class TRDownloadTask: TRTask {

    private var task: URLSessionDataTask?
    
    private var outputStream: OutputStream?

    public init(_ url: URL,
                headers: [String: String]? = nil,
                fileName: String? = nil,
                cache: TRCache,
                isCacheInfo: Bool = false,
                progressHandler: TRTaskHandler? = nil,
                successHandler: TRTaskHandler? = nil,
                failureHandler: TRTaskHandler? = nil) {

        super.init(url,
                   headers: headers,
                   cache: cache,
                   isCacheInfo: isCacheInfo,
                   progressHandler: progressHandler,
                   successHandler: successHandler,
                   failureHandler: failureHandler)
        if let fileName = fileName,
            !fileName.isEmpty {
            self.fileName = fileName
        }
        cache.storeTaskInfo(self)
    }
    

    
    internal override func start() {
        super.start()
        cache.createDirectory()
        
        // 读取缓存中已经下载了的大小
        let path = (cache.downloadTmpPath as NSString).appendingPathComponent(fileName)
        if FileManager().fileExists(atPath: path) {
            if let fileInfo = try? FileManager().attributesOfItem(atPath: path), let length = fileInfo[.size] as? Int64 {
                progress.completedUnitCount = length
            }
        }
        request?.setValue("bytes=\(progress.completedUnitCount)-", forHTTPHeaderField: "Range")
        guard let request = request else { return }
        
        task = session?.dataTask(with: request)

        speed = 0
        progress.setUserInfoObject(progress.completedUnitCount, forKey: .fileCompletedCountKey)

        task?.resume()
        if startDate == 0 {
            startDate = Date().timeIntervalSince1970
        }
        status = .running

    }


    
    internal override func suspend() {
        guard status == .running || status == .waiting else { return }

        if status == .running {
            status = .willSuspend
            task?.cancel()
        }

        if status == .waiting {
            status = .suspended
            TiercelLog("[downloadTask] did suspend, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")
            DispatchQueue.main.tr.safeAsync {
                self.progressHandler?(self)
                self.failureHandler?(self)
            }
            manager?.completed()
        }
    }
    
    internal override func cancel() {
        guard status != .completed else { return }
        if status == .running {
            status = .willCancel
            task?.cancel()
        } else {
            status = .willCancel
            
            manager?.taskDidCancelOrRemove(URLString)
            TiercelLog("[downloadTask] did cancel, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")

            DispatchQueue.main.tr.safeAsync {
                self.failureHandler?(self)
            }
            manager?.completed()
        }
        
    }


    internal override func remove() {
        if status == .running {
            status = .willRemove
            task?.cancel()
        } else {
            status = .willRemove
            manager?.taskDidCancelOrRemove(URLString)
            TiercelLog("[downloadTask] did remove, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")

            DispatchQueue.main.tr.safeAsync {
                self.failureHandler?(self)
            }
            manager?.completed()
        }
    }
    
    internal override func completed() {
        guard status != .completed else { return }
        status = .completed
        endDate = Date().timeIntervalSince1970
        progress.completedUnitCount = progress.totalUnitCount
        timeRemaining = 0
        cache.store(self)
        TiercelLog("[downloadTask] completed, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")
        DispatchQueue.main.tr.safeAsync {
            self.progressHandler?(self)
            self.successHandler?(self)
        }

    }

}



// MARK: - info
extension TRDownloadTask {

    internal func updateSpeedAndTimeRemaining(_ cost: TimeInterval) {

        let dataCount = progress.completedUnitCount
        let lastData: Int64 = progress.userInfo[.fileCompletedCountKey] as? Int64 ?? 0
        
        if dataCount > lastData {
            speed = Int64(Double(dataCount - lastData) / cost)
            updateTimeRemaining()
        }
        progress.setUserInfoObject(dataCount, forKey: .fileCompletedCountKey)

    }

    private func updateTimeRemaining() {
        if speed == 0 {
            self.timeRemaining = 0
        } else {
            let timeRemaining = (Double(progress.totalUnitCount) - Double(progress.completedUnitCount)) / Double(speed)
            self.timeRemaining = Int64(timeRemaining)
            if timeRemaining < 1 && timeRemaining > 0.8 {
                self.timeRemaining += 1
            }
        }
    }
}

// MARK: - download callback
extension TRDownloadTask {
    internal func didReceive(response: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.statusCode >= 200 && response.statusCode <= 209 else {
            TiercelLog("[downloadTask] failed, manager.name: \(manager?.name ?? ""), URLString: \(URLString), response: \(response)")
            status = .failed
            cache.storeTaskInfo(self)
            DispatchQueue.main.tr.safeAsync {
                self.failureHandler?(self)
            }
            completionHandler(.cancel)
            return
        }
        
        if let bytesStr = response.allHeaderFields["Content-Length"] as? String, let totalBytes = Int64(bytesStr) {
            progress.totalUnitCount = totalBytes
        }
        if let contentRangeStr = response.allHeaderFields["content-range"] as? NSString {
            if contentRangeStr.length > 0 {
                progress.totalUnitCount = Int64(contentRangeStr.components(separatedBy: "/").last!)!
            }
        }
        if let contentRangeStr = response.allHeaderFields["Content-Range"] as? NSString {
            if contentRangeStr.length > 0 {
                progress.totalUnitCount = Int64(contentRangeStr.components(separatedBy: "/").last!)!
            }
        }


        if progress.completedUnitCount == progress.totalUnitCount {
            cache.store(self)
            completed()
            manager?.completed()
            completionHandler(.cancel)
            return
        }

        if progress.completedUnitCount > progress.totalUnitCount {
            cache.removeTmpFile(self)
            completionHandler(.cancel)
            // 重新下载
            progress.completedUnitCount = 0
            start()
            return
        }

        let downloadTmpPath = (cache.downloadTmpPath as NSString).appendingPathComponent(fileName)
        outputStream = OutputStream(toFileAtPath: downloadTmpPath, append: true)
        outputStream?.open()

        cache.storeTaskInfo(self)

        completionHandler(.allow)

        TiercelLog("[downloadTask] runing, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")

    }

    internal func didReceive(data: Data) {

        progress.completedUnitCount += Int64((data as NSData).length)
         _ = data.withUnsafeBytes { outputStream?.write($0, maxLength: data.count) }
        manager?.updateSpeedAndTimeRemaining()
        DispatchQueue.main.tr.safeAsync {
            if TRManager.isControlNetworkActivityIndicator {
                UIApplication.shared.isNetworkActivityIndicatorVisible = true
            }
            self.progressHandler?(self)
            self.manager?.updateProgress()
        }
    }

    internal func didComplete(task: URLSessionTask, error: Error?) {
        if TRManager.isControlNetworkActivityIndicator {
            DispatchQueue.main.tr.safeAsync {
                UIApplication.shared.isNetworkActivityIndicatorVisible = false
            }
        }

        session = nil

        outputStream?.close()
        outputStream = nil

        if let error = error {
            self.error = error

            switch status {
            case .willSuspend:
                status = .suspended
                TiercelLog("[downloadTask] did suspend, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")

                DispatchQueue.main.tr.safeAsync {
                    self.progressHandler?(self)
                    self.failureHandler?(self)
                }
            case .willCancel, .willRemove:
                manager?.taskDidCancelOrRemove(URLString)
                if status == .canceled {
                    TiercelLog("[downloadTask] did cancel, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")
                }
                if status == .removed {
                    TiercelLog("[downloadTask] did removed, manager.name: \(manager?.name ?? ""), URLString: \(URLString)")
                }
                DispatchQueue.main.tr.safeAsync {
                    self.failureHandler?(self)
                }
            default:
                status = .failed
                TiercelLog("[downloadTask] failed, manager.name: \(manager?.name ?? ""), URLString: \(URLString), error: \(error)")

                cache.storeTaskInfo(self)
                DispatchQueue.main.tr.safeAsync {
                    self.failureHandler?(self)
                }
            }
        } else {
            completed()
        }

        manager?.completed()
    }
}
