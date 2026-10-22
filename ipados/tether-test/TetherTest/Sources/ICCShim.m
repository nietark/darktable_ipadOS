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

#import "ICCShim.h"

void TTSendPTPCommand(ICCameraDevice *camera, NSData *command, NSData *_Nullable outData, TTPTPCompletion completion)
{
  @try
  {
    [camera requestSendPTPCommand:command
                          outData:outData
                       completion:^(NSData *inData, NSData *response, NSError *error) {
                         completion(inData, response, error);
                       }];
  }
  @catch(NSException *exception)
  {
    NSString *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    completion(nil, nil, [NSError errorWithDomain:@"TetherTest.exception"
                                             code:-1
                                         userInfo:@{ NSLocalizedDescriptionKey : reason }]);
  }
}

void TTRequestAuthorization(ICDeviceBrowser *browser, void (^completion)(NSString *contents, NSString *control))
{
  [browser requestContentsAuthorizationWithCompletion:^(ICAuthorizationStatus contents) {
    [browser requestControlAuthorizationWithCompletion:^(ICAuthorizationStatus control) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(contents ?: @"(nil)", control ?: @"(nil)");
      });
    }];
  }];
}

NSString *TTContentsAuthorizationStatus(ICDeviceBrowser *browser)
{
  return [browser contentsAuthorizationStatus] ?: @"(nil)";
}

NSString *TTControlAuthorizationStatus(ICDeviceBrowser *browser)
{
  return [browser controlAuthorizationStatus] ?: @"(nil)";
}

void TTDownloadFile(ICCameraFile *file, NSURL *directory, void (^completion)(NSString *_Nullable filename, NSError *_Nullable error))
{
  NSDictionary *options = @{ ICDownloadsDirectoryURL : directory };
  [file requestDownloadWithOptions:options
                        completion:^(NSString *filename, NSError *error) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                            completion(filename, error);
                          });
                        }];
}

// KVC, because not every ICDevice property is declared for iOS in every SDK
static id _value(NSObject *object, NSString *key)
{
  @try
  {
    return [object valueForKey:key];
  }
  @catch(NSException *exception)
  {
    return nil;
  }
}

NSInteger TTVendorID(ICDevice *device)
{
  id v = _value(device, @"usbVendorID");
  return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : -1;
}

NSInteger TTProductID(ICDevice *device)
{
  id v = _value(device, @"usbProductID");
  return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : -1;
}

NSString *TTDescribeDevice(ICDevice *device)
{
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for(NSString *key in @[ @"name", @"productKind", @"transportType", @"UUIDString", @"hasOpenSession",
                          @"usbLocationID", @"usbVendorID", @"usbProductID", @"capabilities" ])
  {
    id v = _value(device, key);
    if(!v) continue;
    if([key hasPrefix:@"usbVendor"] || [key hasPrefix:@"usbProduct"])
      [parts addObject:[NSString stringWithFormat:@"%@=0x%04lx", key, (long)[v integerValue]]];
    else if([v isKindOfClass:[NSArray class]])
      [parts addObject:[NSString stringWithFormat:@"%@=[%@]", key, [(NSArray *)v componentsJoinedByString:@", "]]];
    else
      [parts addObject:[NSString stringWithFormat:@"%@=%@", key, v]];
  }
  return [parts componentsJoinedByString:@" "];
}

@implementation TTDeviceEvents

- (void)_note:(NSString *)message
{
  if(self.note) self.note(message);
}

#pragma mark ICDeviceBrowserDelegate

- (void)deviceBrowser:(ICDeviceBrowser *)browser didAddDevice:(ICDevice *)device moreComing:(BOOL)moreComing
{
  if(self.deviceAdded) self.deviceAdded(device);
}

- (void)deviceBrowser:(ICDeviceBrowser *)browser didRemoveDevice:(ICDevice *)device moreGoing:(BOOL)moreGoing
{
  if(self.deviceRemoved) self.deviceRemoved(device);
}

- (void)deviceBrowserDidEnumerateLocalDevices:(ICDeviceBrowser *)browser
{
  [self _note:@"browser: finished enumerating local devices"];
}

#pragma mark ICDeviceDelegate

- (void)didRemoveDevice:(ICDevice *)device
{
  [self _note:[NSString stringWithFormat:@"device: didRemoveDevice %@", device.name]];
}

- (void)device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
  if(self.sessionOpened) self.sessionOpened(device, error);
}

- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error
{
  if(self.sessionClosed) self.sessionClosed(device, error);
}

- (void)deviceDidBecomeReady:(ICDevice *)device
{
  if(self.deviceReady) self.deviceReady(device);
}

- (void)device:(ICDevice *)device didEncounterError:(NSError *)error
{
  [self _note:[NSString stringWithFormat:@"device: error %@", error]];
}

- (void)device:(ICDevice *)device didReceiveStatusInformation:(NSDictionary *)status
{
  [self _note:[NSString stringWithFormat:@"device: status %@", status]];
}

#pragma mark ICCameraDeviceDelegate

- (void)cameraDevice:(ICCameraDevice *)camera didAddItems:(NSArray<ICCameraItem *> *)items
{
  if(self.itemsAdded) self.itemsAdded(camera, items);
}

- (void)cameraDevice:(ICCameraDevice *)camera didRemoveItems:(NSArray<ICCameraItem *> *)items
{
  [self _note:[NSString stringWithFormat:@"camera: %lu item(s) removed", (unsigned long)items.count]];
}

- (void)cameraDevice:(ICCameraDevice *)camera
    didReceiveThumbnail:(CGImageRef)thumbnail
                forItem:(ICCameraItem *)item
                  error:(NSError *)error
{
}

- (void)cameraDevice:(ICCameraDevice *)camera
    didReceiveMetadata:(NSDictionary *)metadata
               forItem:(ICCameraItem *)item
                 error:(NSError *)error
{
}

- (void)cameraDevice:(ICCameraDevice *)camera didRenameItems:(NSArray<ICCameraItem *> *)items
{
}

- (void)cameraDeviceDidChangeCapability:(ICCameraDevice *)camera
{
  [self _note:[NSString stringWithFormat:@"camera: capabilities now [%@]",
                                         [camera.capabilities componentsJoinedByString:@", "]]];
}

- (void)cameraDevice:(ICCameraDevice *)camera didReceivePTPEvent:(NSData *)eventData
{
  if(self.ptpEvent) self.ptpEvent(camera, eventData);
}

- (void)deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)device
{
  if(self.catalogComplete) self.catalogComplete(device);
}

- (void)cameraDeviceDidRemoveAccessRestriction:(ICDevice *)device
{
  [self _note:@"camera: access restriction removed"];
}

- (void)cameraDeviceDidEnableAccessRestriction:(ICDevice *)device
{
  [self _note:@"camera: access restriction enabled (device locked?)"];
}

@end
