//
//  Copyright (c) 2014 Stephane Boisson
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
//  Expanded for CocoaUPnP by A&R Cambridge Ltd, http://www.arcam.co.uk
//  Copyright 2015 Arcam. See LICENSE file.

#import "SSDPServiceBrowser.h"

#import "SSDPService.h"
#import <CocoaUPnP/CocoaUPnP-Swift.h>

//#import <ifaddrs.h>
//#import <sys/socket.h>
//#import <net/if.h>
//#import <arpa/inet.h>

NSString * const SSDPMulticastGroupAddress = @"239.255.255.250";
const UInt16 SSDPMulticastUDPPort = 1900;

NSString *const SSDPVersionString = @"CocoaSSDP/0.1.0";
NSString *const SSDPResponseStatusKey = @"HTTP-Status";
NSString *const SSDPRequestMethodKey = @"HTTP-Method";
//@import CocoaUPnP;


typedef enum : NSUInteger {
    SSDPUnknownMessage,
    SSDPUnexpectedMessage,
    SSDPResponseMessage,
    SSDPSearchMessage,
    SSDPNotifyMessage,
} SSDPMessageType;

@interface SSDPServiceBrowser()<SocketAdapterDelegate> {

}
@property(strong, nonatomic) SocketAdapter *socket;
@end

@implementation SSDPServiceBrowser

#pragma mark - Public Methods

- (void)startBrowsingForServiceTypes:(NSString *)serviceType {
    _socket = [[SocketAdapter alloc] initWithHost:SSDPMulticastGroupAddress port:SSDPMulticastUDPPort];
    _socket.delegate = self;

    NSString *searchHeader;
    searchHeader = [self _prepareSearchRequestWithServiceType:serviceType];
    [_socket sendWithMessage:searchHeader];
}

- (void)stopBrowsingForServices
{
    [_socket close];
    _socket = nil;
}

- (void)socket:(SocketAdapter *)socket didCloseWith:(NSError *)error {
    if (error) {
        [self _notifyDelegateWithError:error];
    }
}

- (void)socket:(SocketAdapter *)socket didReceive:(NSData *)data {
    NSString *msg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!msg) {
        return;
    }

    NSDictionary *headers = [self _parseHeadersFromMessage:msg];
    SSDPService *service = [[SSDPService alloc] initWithHeaders:headers];
    if (!service) { return; }

    if ([headers[SSDPResponseStatusKey] isEqualToString:@"200"]) {
        [self _notifyDelegateWithFoundService:service];
    }

    else if ([headers[SSDPRequestMethodKey] isEqualToString:@"NOTIFY"]) {
        NSString *nts = headers[@"nts"];

        if ( [nts isEqualToString:@"ssdp:alive"] ) {
            [self _notifyDelegateWithFoundService:service];
        }
        else if ([nts isEqualToString:@"ssdp:byebye"]) {
            [self _notifyDelegateWithRemovedService:service];
        }
    }
}

#pragma mark - Private Methods

- (NSMutableDictionary *)_parseHeadersFromMessage:(NSString *)message {
    NSString *pattern = @"^([a-z0-9-]+): *(.+)$";
    NSRegularExpressionOptions options = (NSRegularExpressionCaseInsensitive |
                                          NSRegularExpressionAnchorsMatchLines);
    NSRegularExpression *regex = [NSRegularExpression
                                  regularExpressionWithPattern:pattern
                                  options:options
                                  error:nil];

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    __block SSDPMessageType type = SSDPUnknownMessage;

    [message enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (type == SSDPUnknownMessage) {
            // First line describes type of message
            if([line isEqualToString:@"HTTP/1.1 200 OK"]) {
                type = SSDPResponseMessage;
                [headers setObject:@"200" forKey:SSDPResponseStatusKey];
            }
            else if ([line isEqualToString:@"M-SEARCH * HTTP/1.1"]) {
                type = SSDPSearchMessage;
                [headers setObject:@"M-SEARCH" forKey:SSDPRequestMethodKey];
            }
            else if ([line isEqualToString:@"NOTIFY * HTTP/1.1"]) {
                type = SSDPNotifyMessage;
                [headers setObject:@"NOTIFY" forKey:SSDPRequestMethodKey];
            }
            else {
                type = SSDPUnexpectedMessage;
            }
        }
        else {
            [regex enumerateMatchesInString:line options:0 range:NSMakeRange(0, line.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
                if (result.numberOfRanges == 3) {
                    id object = [line substringWithRange:[result rangeAtIndex:2]];
                    id key = [line substringWithRange:[result rangeAtIndex:1]];
                    [headers setObject:object forKey:[key lowercaseString]];
                }
            }];
        }
    }];

    return headers;
}


- (void)_notifyDelegateWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [self.delegate ssdpBrowser:self didNotStartBrowsingForServices:error];
        }
    });
}

- (void)_notifyDelegateWithFoundService:(SSDPService *)service
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [self.delegate ssdpBrowser:self didFindService:service];
        }
    });
}

- (void)_notifyDelegateWithRemovedService:(SSDPService *)service
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [self.delegate ssdpBrowser:self didRemoveService:service];
        }
    });
}

- (NSString *)_prepareSearchRequestWithServiceType:(NSString *)serviceType {
    NSString *userAgent = [self _userAgentString];

    return [NSString stringWithFormat:
            @"M-SEARCH * HTTP/1.1\r\n"
            "HOST: %@:%d\r\n"
            "MAN: \"ssdp:discover\"\r\n"
            "ST: %@\r\n"
            "MX: 3\r\n"
            "USER-AGENT: %@/1\r\n\r\n\r\n",
            SSDPMulticastGroupAddress,
            SSDPMulticastUDPPort,
            serviceType ?: @"ssdp:all",
            userAgent];
}

- (NSString *)_userAgentString {
    NSString *userAgent = nil;
    NSDictionary *bundleInfos = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleExecutable = bundleInfos[(__bridge NSString *)kCFBundleExecutableKey] ?: bundleInfos[(__bridge NSString *)kCFBundleIdentifierKey];

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
    userAgent = [NSString stringWithFormat:@"%@/%@ (%@; iOS %@) %@",
                 bundleExecutable,
                 (__bridge id)CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), kCFBundleVersionKey) ?: bundleInfos[(__bridge NSString *)kCFBundleVersionKey],
                 [[UIDevice currentDevice] model],
                 [[UIDevice currentDevice] systemVersion], SSDPVersionString];

#elif defined(__MAC_OS_X_VERSION_MIN_REQUIRED)
    userAgent = [NSString stringWithFormat:@"%@/%@ (Mac OS X %@) %@", bundleExecutable,
                 bundleInfos[@"CFBundleShortVersionString"] ?: bundleInfos[(__bridge NSString *)kCFBundleVersionKey],
                 [[NSProcessInfo processInfo] operatingSystemVersionString], SSDPVersionString];
#endif

    return userAgent;
}

@end
