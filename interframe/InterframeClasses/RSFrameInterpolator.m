//
//  RSUpconverter.m
//  interframe
//
//  Created by Ryan Sullivan on 4/7/14.
//  Copyright (c) 2014 RSully. All rights reserved.
//

#import "RSFrameInterpolator.h"
#import <AppKit/AppKit.h>

#define kRSFIBitmapInfo (kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst)
#define kRSFIPixelFormatType kCVPixelFormatType_32BGRA

@interface RSFrameInterpolator ()

@property (strong) NSMutableDictionary *defaultPixelSettings;

// Input assets
@property (strong) AVAsset *inputAsset;
@property (strong) AVAssetTrack *inputAssetVideoTrack;
// Input readers
@property (strong) AVAssetReader *inputAssetVideoReader;
@property (strong) AVAssetReaderTrackOutput *inputAssetVideoReaderOutput;
// Input metadata
@property float inputFPS;
@property NSUInteger inputFrameCount;

// Output writer
@property (strong) AVAssetWriter *outputWriter;
@property (strong) AVAssetWriterInput *outputWriterInput;
@property (strong) AVAssetWriterInputPixelBufferAdaptor *outputWriterInputAdapter;
// Output metadata
@property float outputFPS;
@property NSUInteger outputFrameCount;

@end


@implementation RSFrameInterpolator

-(id)initWithAsset:(AVAsset *)asset output:(NSURL *)output {
    if ((self = [self init]))
    {
        NSError *error = nil;

        self.defaultPixelSettings = [NSMutableDictionary dictionary];
        self.defaultPixelSettings[(NSString *)kCVPixelBufferPixelFormatTypeKey] = @(kRSFIPixelFormatType);


        self.inputAsset = asset;

        // Setup input metadata
        self.inputAssetVideoTrack = [self.inputAsset tracksWithMediaType:AVMediaTypeVideo][0];
        self.inputFPS = self.inputAssetVideoTrack.nominalFrameRate;
        self.inputFrameCount = round(self.inputFPS * CMTimeGetSeconds(self.inputAsset.duration));

        // Calculate expected output metadata
        self.outputFPS = self.inputFPS * 2.0;
        self.outputFrameCount = (self.inputFrameCount * 2.0) - 1;


        // Setup input reader
        self.inputAssetVideoReader = [[AVAssetReader alloc] initWithAsset:self.inputAsset error:&error];
        if (error)
        {
            // TODO: better error system
            @throw [NSException exceptionWithName:@"RSFIException" reason:@"Failed to instantiate inputAssetVideoReader" userInfo:@{@"error": error}];
        }
        self.inputAssetVideoReaderOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:self.inputAssetVideoTrack
                                                                                      outputSettings:self.defaultPixelSettings];
        [self.inputAssetVideoReader addOutput:self.inputAssetVideoReaderOutput];


        // Setup output writer
        NSString *fileType = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)([output pathExtension]), NULL));
        self.outputWriter = [[AVAssetWriter alloc] initWithURL:output fileType:fileType error:&error];
        self.outputWriter.movieTimeScale = NSEC_PER_SEC;

        NSDictionary *outputSettings = @{
                                         AVVideoCodecKey: AVVideoCodecH264,
                                         AVVideoHeightKey: @(self.inputAssetVideoTrack.naturalSize.height),
                                         AVVideoWidthKey: @(self.inputAssetVideoTrack.naturalSize.width),
//                                         AVVideoCompressionPropertiesKey: @{
//                                                 AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
//                                                 AVVideoAverageBitRateKey: @(5000)
//                                                 }
                                         };
        self.defaultPixelSettings[(NSString *)kCVPixelBufferWidthKey] = @(self.inputAssetVideoTrack.naturalSize.width);
        self.defaultPixelSettings[(NSString *)kCVPixelBufferHeightKey] = @(self.inputAssetVideoTrack.naturalSize.height);
        self.defaultPixelSettings[(NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey] = @(YES);
        self.defaultPixelSettings[(NSString *)kCVPixelBufferCGImageCompatibilityKey] = @(YES);

        self.outputWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
//        self.outputWriterInput.expectsMediaDataInRealTime = NO;
        self.outputWriterInputAdapter = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:self.outputWriterInput
                                                                                   sourcePixelBufferAttributes:self.defaultPixelSettings];
        [self.outputWriter addInput:self.outputWriterInput];
    }
    return self;
}


-(CGImageRef)createInterpolatedImageFromPrior:(CGImageRef)imagePrior andNext:(CGImageRef)imageNext
                                     forFrame:(NSUInteger)frame frameCount:(NSUInteger)frameCount {
    if (!self.delegate) return NULL;

    RSFrameInterpolationState *state = [[RSFrameInterpolationState alloc] initWithPriorImage:imagePrior nextImage:imageNext
                                                                                       frame:frame frameCount:frameCount];
    return [self.delegate createInterpolatedImageForInterpolator:self withState:state];
}
-(CGImageRef)createInterpolatedImageFromPrior:(CGImageRef)imagePrior andNext_BAD:(CGImageRef)imageNext {
    // TODO: delegate this logic to interpolator
//    return CGImageCreateCopy(imagePrior);
//    return CGImageCreateCopy(self.placeholderInterpolatedImage);
    CGContextRef context = CGBitmapContextCreate(NULL, CGImageGetWidth(imagePrior), CGImageGetHeight(imagePrior), CGImageGetBitsPerComponent(imagePrior), CGImageGetBytesPerRow(imagePrior), CGImageGetColorSpace(imagePrior), CGImageGetBitmapInfo(imagePrior));
    CGContextSetAlpha(context, 0.5);
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(imagePrior), CGImageGetHeight(imagePrior)), imagePrior);
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(imagePrior), CGImageGetHeight(imagePrior)), imageNext);

    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    return result;
}
-(void)interpolate {

    BOOL readingOK = [self.inputAssetVideoReader startReading];
    if (!readingOK)
    {
        @throw [NSException exceptionWithName:@"RSFIException" reason:@"Failed to read inputAssetVideoReader" userInfo:nil];
    }
    BOOL writingOK = [self.outputWriter startWriting];
    if (!writingOK)
    {
        @throw [NSException exceptionWithName:@"RSFIException" reason:@"Failed to write outputWriter" userInfo:nil];
    }
    [self.outputWriter startSessionAtSourceTime:kCMTimeZero];

    NSUInteger framePrior, frameInbetween, frameNext;
    CMSampleBufferRef sampleBufferPrior = NULL, sampleBufferNext = NULL;
    CVPixelBufferRef pixelBufferPrior = NULL, pixelBufferInbetween = NULL, pixelBufferNext = NULL;
    CGImageRef imagePrior = NULL, imageInbetween = NULL, imageNext = NULL;
    CMTime timePrior, timeInbetween, timeNext;

    // expr         explain                 output      input
    // -----------------------------------------------------------
    // frame - 2 = first source frame   // 1 3 5    // 1 2 3
    // frame - 1 = inbetween frame      // 2 4 6    //
    // frame - 0 = last source frame    // 3 5 7    // 2 3 4
    // -----------------------------------------------------------
    for (NSUInteger frame = 3; frame <= self.outputFrameCount; frame += 2)
    {
        // TODO: remove, debug only
        if (frame > 1200) break;

        // Frame numbers for output
        framePrior = frame - 2;
        frameInbetween = frame - 1;
        frameNext = frame;

        // Frame times
        timePrior = CMTimeMakeWithSeconds(framePrior / self.outputFPS, NSEC_PER_SEC);
        timeInbetween = CMTimeMakeWithSeconds(frameInbetween / self.outputFPS, NSEC_PER_SEC);
        timeNext = CMTimeMakeWithSeconds(frameNext / self.outputFPS, NSEC_PER_SEC);


        // Handle first frame special
        if (framePrior == 0)
        {
            sampleBufferPrior = [self.inputAssetVideoReaderOutput copyNextSampleBuffer];
            pixelBufferPrior = CMSampleBufferGetImageBuffer(sampleBufferPrior);
            imagePrior = [self createCGImageFromPixelBuffer:pixelBufferPrior];

            // We don't want to duplicate writes, so do it here
            [self lazilyAppendPixelBuffer:pixelBufferPrior withPresentationTime:timePrior];

            CFRelease(sampleBufferPrior), sampleBufferPrior = NULL;
        }

        sampleBufferNext = [self.inputAssetVideoReaderOutput copyNextSampleBuffer];
        pixelBufferNext = CMSampleBufferGetImageBuffer(sampleBufferNext);
        imageNext = [self createCGImageFromPixelBuffer:pixelBufferNext];


        imageInbetween = [self createInterpolatedImageFromPrior:imagePrior andNext:imageNext
                                                       forFrame:frameInbetween frameCount:self.outputFrameCount];
        pixelBufferInbetween = [self createPixelBufferFromCGImage:imageInbetween];
        if (!pixelBufferInbetween)
        {
            NSLog(@"Failed to create pixel buffer");
        }
        else
        {
            [self lazilyAppendPixelBufferAsSampleBuffer:pixelBufferInbetween withPresentationTime:timeInbetween];
        }

        [self lazilyAppendPixelBuffer:pixelBufferNext withPresentationTime:timeNext];



        // Cleanup
        CVPixelBufferRelease(pixelBufferInbetween), pixelBufferInbetween = NULL;
        CGImageRelease(imageInbetween), imageInbetween = NULL;
        CGImageRelease(imagePrior), imagePrior = NULL;
        CFRelease(sampleBufferNext), sampleBufferNext = NULL;
        // We need to keep this around to generate the next inbetween
        imagePrior = imageNext;

    }

    if (imagePrior) {
        CGImageRelease(imagePrior), imagePrior = NULL;
    }

    NSLog(@"Going to finish writing...");
    [self.outputWriterInput markAsFinished];
    [self.outputWriter finishWritingWithCompletionHandler:^{
        NSLog(@"Finished writing");
        [self.delegate interpolatorFinished:self];
        // TODO: ?
    }];

}

-(void)lazilyAppendPixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime {
    while (!self.outputWriterInput.readyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.005];
    }

    NSLog(@"{%lld / %d => %f}", presentationTime.value, presentationTime.timescale, CMTimeGetSeconds(presentationTime));
    BOOL result = [self.outputWriterInputAdapter appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
    if (!result)
    {
        NSLog(@"failed to append pixel buffer %@", self.outputWriter.error);
    }
    NSLog(@"finished -lazilyAppendPixelBuffer");
}
-(void)lazilyAppendPixelBufferAsSampleBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime {
    CMSampleBufferRef sampleBuffer = NULL;
    CMVideoFormatDescriptionRef formatDescription = NULL;

    CMSampleTimingInfo *sampleTiming = malloc(sizeof(CMSampleTimingInfo));
    sampleTiming->decodeTimeStamp = kCMTimeInvalid;
    sampleTiming->duration = CMTimeMakeWithSeconds(1 / self.outputFPS, NSEC_PER_SEC);
    sampleTiming->presentationTimeStamp = presentationTime;

    OSStatus fStatus = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &formatDescription);
    if (fStatus != 0)
    {
        NSLog(@"fStatus %d", fStatus);
    }
    OSStatus sStatus = CMSampleBufferCreateForImageBuffer(NULL, pixelBuffer, YES, NULL, NULL, formatDescription, sampleTiming, &sampleBuffer);
    if (sStatus != 0)
    {
        NSLog(@"sStatus %d", sStatus);
    }

    [self lazilyAppendSampleBuffer:sampleBuffer];
}
-(void)lazilyAppendSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    while (!self.outputWriterInput.readyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.01];
    }

    BOOL result = [self.outputWriterInput appendSampleBuffer:sampleBuffer];
    if (!result)
    {
        NSLog(@"failed to append sample buffer %@", self.outputWriter.error);
    }
    NSLog(@"finished -lazilyAppendSampleBuffer");
}

/**
 * Create a CGImage from a CVPixelBuffer
 * This may only work on 32BGRA sources
 *
 * Some logic from: http://stackoverflow.com/questions/3305862/uiimage-created-from-cmsamplebufferref-not-displayed-in-uiimageview
 */
-(CGImageRef)createCGImageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    CGContextRef context = [self createContextFromPixelBuffer:pixelBuffer];

    // Fetch the image
    CGImageRef image = CGBitmapContextCreateImage(context);

    // Cleanup
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return image;
}
/**
 * Create a CVPixelBuffer from a CGImage
 */
-(CVPixelBufferRef)createPixelBufferFromCGImage:(CGImageRef)image {
    CVPixelBufferRef pixelBuffer = [self createPixelBuffer];
    if (!pixelBuffer)
    {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    CGContextRef context = [self createContextFromPixelBuffer:pixelBuffer];

    // Draw the image onto pixelBuffer
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);

    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return pixelBuffer;
}

-(CGContextRef)createContextFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // Get info about image
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    // Using device RGB - is this best?
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, colorSpace, kRSFIBitmapInfo);

    // Cleanup
    CGColorSpaceRelease(colorSpace);

    return context;
}
-(CVPixelBufferRef)createPixelBuffer {
    NSLog(@"-createPixelBuffer");
    CVPixelBufferRef pixelBuffer = NULL;

    CVPixelBufferPoolRef pool = self.outputWriterInputAdapter.pixelBufferPool;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
    // Use this for debugging if the pool doesn't work:
//    CVReturn status = CVPixelBufferCreate(NULL, [(NSNumber *)self.outputWriterInput.outputSettings[AVVideoWidthKey] unsignedIntegerValue], [(NSNumber *)self.outputWriterInput.outputSettings[AVVideoHeightKey] unsignedIntegerValue], kRSFIPixelFormatType, (__bridge CFDictionaryRef)(self.defaultPixelSettings), &pixelBuffer);

    if (status != kCVReturnSuccess)
    {
        NSLog(@"Failed to create pixel buffer (%d)", status);
        return NULL;
    }

    return pixelBuffer;
}

@end
