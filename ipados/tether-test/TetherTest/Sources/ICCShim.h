/*
    This file is part of the darktable iPadOS tethering test app.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// thin Objective-C layer over ImageCaptureCore.
//
// two reasons it is not Swift: the delegate protocols are matched by
// selector here, so a misspelled optional method is a warning instead of a
// build failure, and the PTP completion block receives nullable NSData. Apple
// DTS traced crashes after long sessions (developer forums thread 740412) to
// the Swift bridge of that block; here a nil reply reaches Swift as nil
// instead of trapping.

#import <Foundation/Foundation.h>
#import <ImageCaptureCore/ImageCaptureCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TTPTPCompletion)(NSData *_Nullable inData, NSData *_Nullable response, NSError *_Nullable error);

// sends one PTP command container; never throws, reports exceptions as errors
void TTSendPTPCommand(ICCameraDevice *camera, NSData *command, NSData *_Nullable outData, TTPTPCompletion completion);

// asks for contents then control authorization and reports both raw statuses
void TTRequestAuthorization(ICDeviceBrowser *browser, void (^completion)(NSString *contents, NSString *control));
NSString *TTContentsAuthorizationStatus(ICDeviceBrowser *browser);
NSString *TTControlAuthorizationStatus(ICDeviceBrowser *browser);

// downloads a file the camera announced (receive-only fallback)
void TTDownloadFile(ICCameraFile *file, NSURL *directory, void (^completion)(NSString *_Nullable filename, NSError *_Nullable error));

// one-line description of everything ImageCaptureCore reports about a device
NSString *TTDescribeDevice(ICDevice *device);
NSInteger TTVendorID(ICDevice *device);
NSInteger TTProductID(ICDevice *device);

// every ImageCaptureCore callback the test app listens to, forwarded to blocks.
// all of them arrive on the main thread.
@interface TTDeviceEvents : NSObject <ICDeviceBrowserDelegate, ICCameraDeviceDelegate>
@property (nonatomic, copy, nullable) void (^deviceAdded)(ICDevice *device);
@property (nonatomic, copy, nullable) void (^deviceRemoved)(ICDevice *device);
@property (nonatomic, copy, nullable) void (^sessionOpened)(ICDevice *device, NSError *_Nullable error);
@property (nonatomic, copy, nullable) void (^sessionClosed)(ICDevice *device, NSError *_Nullable error);
@property (nonatomic, copy, nullable) void (^deviceReady)(ICDevice *device);
@property (nonatomic, copy, nullable) void (^catalogComplete)(ICCameraDevice *camera);
@property (nonatomic, copy, nullable) void (^itemsAdded)(ICCameraDevice *camera, NSArray<ICCameraItem *> *items);
@property (nonatomic, copy, nullable) void (^ptpEvent)(ICCameraDevice *camera, NSData *event);
@property (nonatomic, copy, nullable) void (^note)(NSString *message);
@end

NS_ASSUME_NONNULL_END
