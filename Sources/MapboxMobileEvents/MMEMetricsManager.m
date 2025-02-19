#import "MMEMetricsManager.h"
#import "MMEReachability.h"
#import "MMEConstants.h"
#import "MMEDate.h"
#import "MMEEvent.h"
#import "MMEEventsManager.h"
#import "MMECommonEventData.h"
#import "MMEAPIClient.h"
#import "MMEAPIClient_Private.h"
#import "NSUserDefaults+MMEConfiguration.h"
#import "MMEEventLogger.h"

#pragma mark -

@interface MMEEventsManager (Private)

- (void)pushEvent:(MMEEvent *)event;

@property (nonatomic) MMECommonEventData *commonEventData;
@property (nonatomic) MMEAPIClient *apiClient;

@end

#pragma mark -

@interface MMEMetricsManager ()

@property (nonatomic, readonly, strong) NSRecursiveLock *lock;
@property (nonatomic) MMEMetrics *metrics;

@end

#pragma mark -

@implementation MMEMetricsManager

+ (instancetype)sharedManager {
    static MMEMetricsManager *_sharedManager;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedManager = [[MMEMetricsManager alloc] init];
    });
    
    return _sharedManager;
}

+ (NSString *)pendingMetricsEventPath {
    static NSString *pendingMetricFile = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSString *libraryPath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).lastObject;
        NSString *frameworkLibraryPath = [libraryPath stringByAppendingPathComponent:[NSBundle bundleForClass:self].bundleIdentifier];

        pendingMetricFile = [frameworkLibraryPath stringByAppendingPathComponent:@"pending-metrics.event"];
    });

    return pendingMetricFile;
}

/*! @brief Remove any existing pending metrics event, logging any errors that occur */
+ (BOOL)deletePendingMetricsEventFile {
    BOOL success = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:MMEMetricsManager.pendingMetricsEventPath]) {
        NSError *fileError = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:MMEMetricsManager.pendingMetricsEventPath error:&fileError]) {
            MMEEvent *errorEvent = [MMEEvent debugEventWithError:fileError];
            [MMEEventLogger.sharedLogger logEvent:errorEvent];
        }
        else {  // we successfully removed the file
            success = YES;
        }
    }
    else { // there was no file to begin with
        success = YES;
    }

    return success;
}

+ (BOOL)createFrameworkMetricsEventDir {
    NSString *sdkPath = MMEMetricsManager.pendingMetricsEventPath.stringByDeletingLastPathComponent;
    BOOL sdkPathIsDir = NO;
    BOOL sdkPathExtant = [NSFileManager.defaultManager fileExistsAtPath:sdkPath isDirectory:&sdkPathIsDir];
    NSError* sdkPathError = nil;

    if (!sdkPathIsDir) { // remove it
        if ([NSFileManager.defaultManager removeItemAtPath:sdkPath error:&sdkPathError]) {
            sdkPathExtant = NO;
        }
        else {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithError:sdkPathError]];
        }
    }

    if (!sdkPathExtant) { // create it
        if ([NSFileManager.defaultManager createDirectoryAtPath:sdkPath withIntermediateDirectories:YES attributes:nil error:&sdkPathError]) {
            if ([[NSURL fileURLWithPath:sdkPath] setResourceValue:@(YES) forKey:NSURLIsExcludedFromBackupKey error:&sdkPathError]) {
                sdkPathIsDir = YES;
            }
            else {
                [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithError:sdkPathError]];
            }
        }
        else {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithError:sdkPathError]];
        }
    }

    return sdkPathIsDir;
}

#pragma mark -

- (instancetype)init {
    if (self = [super init]) {
        [self resetMetrics];
        _lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)updateMetricsFromEventQueue:(NSArray *)eventQueue {
    if (eventQueue.count > 0) {
        [self.lock lock];
        self.metrics.eventCountTotal += eventQueue.count;
        
        for (MMEEvent *event in eventQueue) {
            NSNumber *eventCount = [self.metrics.eventCountPerType objectForKey:event.name];
            eventCount = [NSNumber numberWithInteger:[eventCount integerValue] + 1];
            [self.metrics.eventCountPerType setObject:eventCount forKey:event.name];
        }
        [self.lock unlock];
    }
}

- (void)updateMetricsFromEventCount:(NSUInteger)eventCount request:(nullable NSURLRequest *)request error:(nullable NSError *)error {
    [self.lock lock];
    if (request.HTTPBody) {
        [self updateSentBytes:request.HTTPBody.length];
    }
    
    if (request == nil && error == nil) {
        [self updateEventsFailedCount:eventCount];
    } else if (error == nil) {
        //successful request -- the events for this are counted elsewhere
        self.metrics.requests++;
    } else {
        [self updateEventsFailedCount:eventCount];

        NSHTTPURLResponse *response = (NSHTTPURLResponse *)[error.userInfo objectForKey:MMEResponseKey];
        NSString *urlString = response.URL.absoluteString;
        NSNumber *statusCode = @(response.statusCode);
        NSString *statusCodeKey = [statusCode stringValue];
        
        if (urlString && [self.metrics.failedRequestsDict objectForKey:MMEEventKeyHeader] == nil) {
            [self.metrics.failedRequestsDict setObject:urlString forKey:MMEEventKeyHeader];
        }
    
        if ([self.metrics.failedRequestsDict objectForKey:MMEEventKeyFailedRequests] == nil) {
            [self.metrics.failedRequestsDict setObject:[NSMutableDictionary new] forKey:MMEEventKeyFailedRequests];
        }
        
        NSMutableDictionary *failedRequests = [self.metrics.failedRequestsDict objectForKey:MMEEventKeyFailedRequests];
        
        NSNumber *failedCount = [failedRequests objectForKey:statusCodeKey];
        failedCount = [NSNumber numberWithInteger:[failedCount integerValue] + 1];
        [failedRequests setObject:failedCount forKey:statusCodeKey];
        
        [self.metrics.failedRequestsDict setObject:failedRequests forKey:MMEEventKeyFailedRequests];
    }
    [self.lock unlock];
}

- (void)updateEventsFailedCount:(NSUInteger)eventCount {
    [self.lock lock];
    self.metrics.eventCountFailed += eventCount;
    [self.lock unlock];
}

- (void)updateSentBytes:(NSUInteger)bytes {
    [self.lock lock];
    if ([[MMEReachability reachabilityForLocalWiFi] isReachableViaWiFi]) {
        self.metrics.wifiBytesSent += bytes;
    } else {
        self.metrics.cellBytesSent += bytes;
    }
    [self.lock unlock];
}

- (void)updateReceivedBytes:(NSUInteger)bytes {
    [self.lock lock];
    if ([[MMEReachability reachabilityForLocalWiFi] isReachableViaWiFi]) {
        self.metrics.wifiBytesReceived += bytes;
    } else {
        self.metrics.cellBytesReceived += bytes;
    }
    [self.lock unlock];
}

- (void)incrementAppWakeUpCount {
    [self.lock lock];
    self.metrics.appWakeups++;
    [self.lock unlock];
}

- (void)updateConfigurationJSON:(NSDictionary *)configuration {
    if (configuration) {
        [self.lock lock];
        self.metrics.configResponseDict = configuration;
        [self.lock unlock];
    }
}

- (void)updateCoordinate:(CLLocationCoordinate2D)coordinate {
    [self.lock lock];
    if (!self.metrics.deviceLat && !self.metrics.deviceLon) {
        self.metrics.deviceLat = round(coordinate.latitude*1000)/1000;
        self.metrics.deviceLon = round(coordinate.longitude*1000)/1000;
    }
    [self.lock unlock];
}

- (void)resetMetrics {
    [self.lock lock];
    self.metrics = [MMEMetrics new];
    [self.lock unlock];
}

- (void)incrementLocationsInForeground {
    [self.lock lock];
    self.metrics.locationsInForeground++;
    [self.lock unlock];
}
- (void)incrementLocationsInBackground {
    [self.lock lock];
    self.metrics.locationsInBackground++;
    [self.lock unlock];
}
- (void)incrementLocationsWithApproximateValues {
    [self.lock lock];
    self.metrics.locationsWithApproximateValues++;
    [self.lock unlock];
}

- (void)incrementLocationsDroppedBecauseOfHAF {
    [self.lock lock];
    self.metrics.locationsDroppedBecauseOfHAF++;
    [self.lock unlock];
}

- (void)incrementLocationsDroppedDueTimeout {
    [self.lock lock];
    self.metrics.locationsDroppedDueTimeout++;
    [self.lock unlock];
}

- (void)incrementLocationsConvertedIntoEvents {
    [self.lock lock];
    self.metrics.locationsConvertedIntoEvents++;
    [self.lock unlock];
}

- (NSDictionary *)attributes {
    [self.lock lock];
    MMEMutableMapboxEventAttributes *attributes = [MMEMutableMapboxEventAttributes dictionary];
    if (self.metrics.recordingStarted) {
        attributes[MMEEventDateUTC] = [MMEDate.iso8601DateOnlyFormatter stringFromDate:self.metrics.recordingStarted];
    }
    attributes[MMEEventKeyFailedRequests] = [self jsonStringfromDict:self.metrics.failedRequestsDict];
    attributes[MMEEventEventCountPerType] = [self jsonStringfromDict:self.metrics.eventCountPerType];
    attributes[MMEEventConfigResponse] = [self jsonStringfromDict:self.metrics.configResponseDict];
    attributes[MMEEventTotalDataSent] = @(self.metrics.totalBytesSent);
    attributes[MMEEventCellDataSent] = @(self.metrics.cellBytesSent);
    attributes[MMEEventWiFiDataSent] = @(self.metrics.wifiBytesSent);
    attributes[MMEEventTotalDataReceived] = @(self.metrics.totalBytesReceived);
    attributes[MMEEventCellDataReceived] = @(self.metrics.cellBytesReceived);
    attributes[MMEEventWiFiDataReceived] = @(self.metrics.wifiBytesReceived);
    attributes[MMEEventEventCountFailed] = @(self.metrics.eventCountFailed);
    attributes[MMEEventEventCountTotal] = @(self.metrics.eventCountTotal);
    attributes[MMEEventEventCountMax] = @(self.metrics.eventCountMax);
    attributes[MMEEventAppWakeups] = @(self.metrics.appWakeups);
    attributes[MMEEventRequests] = @(self.metrics.requests);
    attributes[MMEEventDeviceTimeDrift] = @(MMEDate.recordedTimeOffsetFromServer);
    if (self.metrics.deviceLat != 0 && self.metrics.deviceLon != 0) {
        attributes[MMEEventDeviceLat] = @(self.metrics.deviceLat);
        attributes[MMEEventDeviceLon] = @(self.metrics.deviceLon);
    }
    attributes[MMEEventKeyLocationsForeground] = @(self.metrics.locationsInForeground);
    attributes[MMEEventKeyLocationsBackground] = @(self.metrics.locationsInBackground);
    attributes[MMEEventKeyLocationsWithApproximateValues] = @(self.metrics.locationsWithApproximateValues);
    attributes[MMEEventKeyLocationsDroppedBecauseOfHAF] = @(self.metrics.locationsDroppedBecauseOfHAF);
    attributes[MMEEventKeyLocationsDroppedDueTimeout] = @(self.metrics.locationsDroppedDueTimeout);
    attributes[MMEEventKeyLocationsConvertedIntoEvents] = @(self.metrics.locationsConvertedIntoEvents);

    attributes[MMEEventKeyModel] = [MMEEventsManager sharedManager].commonEventData.model;
    attributes[MMEEventKeyOperatingSystem] = [MMEEventsManager sharedManager].commonEventData.osVersion;
    attributes[MMEEventKeyPlatform] = [MMEEventsManager sharedManager].commonEventData.platform;
    attributes[MMEEventKeyDevice] = [MMEEventsManager sharedManager].commonEventData.device;
    
    attributes[MMEEventSDKIdentifier] = NSUserDefaults.mme_configuration.mme_legacyUserAgentBase;
    attributes[MMEEventSDKVersion] = NSUserDefaults.mme_configuration.mme_legacyHostSDKVersion;
    attributes[MMEEventKeyUserAgent] = NSUserDefaults.mme_configuration.mme_userAgentString;
    [self.lock unlock];

    return attributes;
}

- (MMEEvent *)loadPendingTelemetryMetricsEvent {
    MMEEvent* pending = nil;

    if ([NSFileManager.defaultManager fileExistsAtPath:MMEMetricsManager.pendingMetricsEventPath]) {
        @try {
            NSData *thenData = [NSData dataWithContentsOfFile:MMEMetricsManager.pendingMetricsEventPath];
            NSKeyedUnarchiver* unarchiver = [NSKeyedUnarchiver.alloc initForReadingWithData:thenData];
            unarchiver.requiresSecureCoding = YES;
            pending = [unarchiver decodeObjectOfClass:MMEEvent.class forKey:NSKeyedArchiveRootObjectKey];
        }
        @catch (NSException *exception) {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithException:exception]];
        }
    }
    //decoding failed; deleting metrics event
    if (pending == nil) {
        [MMEMetricsManager deletePendingMetricsEventFile];
    }
    return pending;
}

- (MMEEvent *)generateTelemetryMetricsEvent {
    [self.lock lock];
    NSDate *zeroHour = [self.metrics.recordingStarted mme_startOfTomorrow];
    [self.lock unlock];
    NSString *metricsDate = [MMEDate.iso8601DateFormatter stringFromDate:NSDate.date];
    MMEEvent *telemetryMetrics = [MMEEvent telemetryMetricsEventWithDateString:metricsDate attributes:self.attributes];

    if (zeroHour.timeIntervalSinceNow > 0) { // it's not time to send metrics yet
        if (@available(iOS 10.0, macos 10.12, tvOS 10.0, watchOS 3.0, *)) { // write them to a pending file
            [MMEMetricsManager deletePendingMetricsEventFile];

            if ([MMEMetricsManager createFrameworkMetricsEventDir]) {
                @try { // to write the metrics event to the pending metrics event path
                    NSKeyedArchiver *archiver = [NSKeyedArchiver new];
                    archiver.requiresSecureCoding = YES;
                    [archiver encodeObject:telemetryMetrics forKey:NSKeyedArchiveRootObjectKey];

                    if (![archiver.encodedData writeToFile:MMEMetricsManager.pendingMetricsEventPath atomically:YES]) {
                        MMELOG(MMELogInfo, MMEDebugEventTypeTelemetryMetrics, ([NSString stringWithFormat:@"Failed to archiveRootObject: %@ toFile: %@",
                        telemetryMetrics, MMEMetricsManager.pendingMetricsEventPath]));
                    }
                }
                @catch (NSException* exception) {
                    [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithException:exception]];
                }
            }
        }
        return nil;
    }
    [MMEEventLogger.sharedLogger logEvent:telemetryMetrics];
    [MMEMetricsManager deletePendingMetricsEventFile];
    
    return telemetryMetrics;
}

#pragma mark -

- (NSString *)jsonStringfromDict:(NSDictionary *)dictionary {
    //prevents empty dictionaries from being stringified
    if ([dictionary count] > 0) {
        NSString *jsonString;
        NSError *jsonError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&jsonError];
        
        if (jsonData) {
            jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        } else if (jsonError) {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithError:jsonError]];
        }
        return jsonString;
    }
    return nil;
}

@end
