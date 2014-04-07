//
//  RSUpconverter.h
//  interframe
//
//  Created by Ryan Sullivan on 4/7/14.
//  Copyright (c) 2014 RSully. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>


@interface RSFrameInterpolator : NSObject

-(id)initWithAsset:(AVAsset *)asset output:(NSURL *)output;

-(void)interpolate;

@end
