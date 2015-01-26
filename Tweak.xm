#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <objc/runtime.h>

/* 
TODO:
- Hide bottom half of Waveform
- "Thicken" bars (more soundcloud-y)
- use ARC? maybe not?
- Remote abilities for e.g. Music->SpringBoard

*/

BOOL useLogWaveform = NO;
BOOL useSoundCloudyRenderer = NO;

@protocol WMWaveformViewDelegate <NSObject>
@optional
- (void)waveformViewWillRender:(id)waveformView;
- (void)waveformViewDidRender:(id)waveformView;
- (void)waveformViewWillLoad:(id)waveformView;
- (void)waveformViewDidLoad:(id)waveformView;
- (void)waveformViewDidScrub:(CGFloat)value;
@end

@interface WMWaveformView : UIView
@property (nonatomic, weak) id delegate;
- (void)setAVAsset:(AVAsset*)asset;
@property (nonatomic, assign, readonly) unsigned long int totalSamples;
@property (nonatomic, assign) unsigned long int progressSamples;
@property (nonatomic, assign) unsigned long int zoomStartSamples;
@property (nonatomic, assign) unsigned long int zoomEndSamples;
@property (nonatomic) BOOL doesAllowScrubbing;
@property (nonatomic) BOOL doesAllowStretchAndScroll;
@property (nonatomic, copy) UIColor *wavesColor;
@property (nonatomic, copy) UIColor *progressColor;
- (void)setProgressSamples:(unsigned long)progressSamples animate:(BOOL)animate;

@property (nonatomic) BOOL CANCEL;
@end

// Adapted from FDWaveformView @ https://github.com/fulldecent/FDWaveformView/tree/master/FDWaveformView
// and https://stackoverflow.com/questions/5032775/drawing-waveform-with-avassetreader
#define minMaxX(x,mn,mx) (x<=mn?mn:(x>=mx?mx:x))
#define noiseFloor (-50.0)
#define decibel(amplitude) (20.0 * log10(abs(amplitude)/32767.0))

// Drawing a larger image than needed to have it available for scrolling
#define horizontalMinimumBleed 0.1
#define horizontalMaximumBleed 3
#define horizontalTargetBleed 0.5
// Drawing more pixels than shown to get antialiasing
#define horizontalMinimumOverdraw 2
#define horizontalMaximumOverdraw 5
#define horizontalTargetOverdraw 3
#define verticalMinimumOverdraw 1
#define verticalMaximumOverdraw 3
#define verticalTargetOverdraw 2

@interface WMWaveformView() <UIGestureRecognizerDelegate> {
}
@property (nonatomic, strong) UIImageView *image;
@property (nonatomic, strong) UIImageView *highlightedImage;
@property (nonatomic, strong) UIView *clipping;
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, assign) unsigned long int totalSamples;
@property (nonatomic, assign) unsigned long int cachedStartSamples;
@property (nonatomic, assign) unsigned long int cachedEndSamples;
@property (nonatomic, strong) UIPinchGestureRecognizer *pinchRecognizer;
@property (nonatomic, strong) UIPanGestureRecognizer *panRecognizer;
@property (nonatomic, strong) UITapGestureRecognizer *tapRecognizer;
@property BOOL renderingInProgress;
@property BOOL loadingInProgress;
@end

@implementation WMWaveformView

- (void)initialize
{
	self.CANCEL = NO;
    self.image = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, self.frame.size.width, self.frame.size.height)];
    self.highlightedImage = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, self.frame.size.width, self.frame.size.height)];
    self.image.contentMode = UIViewContentModeScaleToFill;
    self.highlightedImage.contentMode = UIViewContentModeScaleToFill;
    [self addSubview:self.image];
    self.clipping = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.frame.size.width, self.frame.size.height)];
    [self.clipping addSubview:self.highlightedImage];
    self.clipping.clipsToBounds = YES;
    [self addSubview:self.clipping];
    self.clipsToBounds = YES;
    
    self.wavesColor = [UIColor blackColor];
    self.progressColor = [UIColor blueColor];
    
    self.pinchRecognizer = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
    self.pinchRecognizer.delegate = self;
    [self addGestureRecognizer:self.pinchRecognizer];

    self.panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    self.panRecognizer.delegate = self;
    [self addGestureRecognizer:self.panRecognizer];
    
    self.tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapGesture:)];
    [self addGestureRecognizer:self.tapRecognizer];
}

- (instancetype)initWithCoder:(NSCoder *)aCoder
{
    if (self = [super initWithCoder:aCoder])
        [self initialize];
    return self;
}

- (instancetype)initWithFrame:(CGRect)rect
{
    if (self = [super initWithFrame:rect])
        [self initialize];
    return self;
}

- (void)setAVAsset:(AVAsset*)asset
{
    self.loadingInProgress = YES;
    if ([self.delegate respondsToSelector:@selector(waveformViewWillLoad:)])
        [self.delegate waveformViewWillLoad:self];
    self.asset = asset;

    [self.asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^() {
        self.loadingInProgress = NO;
        if ([self.delegate respondsToSelector:@selector(waveformViewDidLoad:)])
            [self.delegate waveformViewDidLoad:self];
        
        NSError *error = nil;
        AVKeyValueStatus durationStatus = [self.asset statusOfValueForKey:@"duration" error:&error];
        switch (durationStatus) {
            case AVKeyValueStatusLoaded:
                self.image.image = nil;
                self.highlightedImage.image = nil;
                self.totalSamples = (unsigned long int) self.asset.duration.value;
                _progressSamples = 0;
                _zoomStartSamples = 0;
                _zoomEndSamples = (unsigned long int) self.asset.duration.value; 
                [self setNeedsDisplay];
                [self performSelectorOnMainThread:@selector(setNeedsLayout) withObject:nil waitUntilDone:NO];
                break;
                
            case AVKeyValueStatusUnknown:
            case AVKeyValueStatusLoading:
            case AVKeyValueStatusFailed:
            case AVKeyValueStatusCancelled:
                NSLog(@"WaveMusic: could not load asset: %@", error.localizedDescription);
                break;
        }
    }];
}

- (void)setProgressSamples:(unsigned long)progressSamples
{
	[self setProgressSamples:progressSamples animate:NO];
}

- (void)setProgressSamples:(unsigned long)progressSamples animate:(BOOL)animate
{
    _progressSamples = progressSamples;
    if (self.totalSamples) {
        CGFloat progress = (CGFloat)self.progressSamples / self.totalSamples;
        [UIView animateWithDuration:animate ? 1 : 0
                      delay:0
                    options:UIViewAnimationOptionTransitionNone
                 animations:^{
        	self.clipping.frame = CGRectMake(0, 0, self.frame.size.width * progress, self.frame.size.height);
        	[self setNeedsLayout];
        } completion:nil];
    }
}

- (void)setZoomStartSamples:(unsigned long)startSamples
{
    _zoomStartSamples = startSamples;
    [self setNeedsDisplay];
    [self setNeedsLayout];
}

- (void)setZoomEndSamples:(unsigned long)endSamples
{
    _zoomEndSamples = endSamples;
    [self setNeedsDisplay];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    if (!self.asset || self.renderingInProgress || self.zoomEndSamples == 0)
        return;
    
    unsigned long int displayRange = self.zoomEndSamples - self.zoomStartSamples;
    BOOL needToRender = NO;
    if (!self.image.image)
        needToRender = YES;
    if (self.cachedStartSamples < (unsigned long)minMaxX((CGFloat)self.zoomStartSamples - displayRange * horizontalMaximumBleed, 0, self.totalSamples))
        needToRender = YES;
    if (self.cachedStartSamples > (unsigned long)minMaxX((CGFloat)self.zoomStartSamples - displayRange * horizontalMinimumBleed, 0, self.totalSamples))
        needToRender = YES;
    if (self.cachedEndSamples < (unsigned long)minMaxX((CGFloat)self.zoomEndSamples + displayRange * horizontalMinimumBleed, 0, self.totalSamples))
        needToRender = YES;
    if (self.cachedEndSamples > (unsigned long)minMaxX((CGFloat)self.zoomEndSamples + displayRange * horizontalMaximumBleed, 0, self.totalSamples))
        needToRender = YES;
    if (self.image.image.size.width < self.frame.size.width * [UIScreen mainScreen].scale * horizontalMinimumOverdraw)
        needToRender = YES;
    if (self.image.image.size.width > self.frame.size.width * [UIScreen mainScreen].scale * horizontalMaximumOverdraw)
        needToRender = YES;
    if (self.image.image.size.height < self.frame.size.height * [UIScreen mainScreen].scale * verticalMinimumOverdraw)
        needToRender = YES;
    if (self.image.image.size.height > self.frame.size.height * [UIScreen mainScreen].scale * verticalMaximumOverdraw)
        needToRender = YES;
    if (!needToRender) {
        // We need to place the images which have samples from cachedStart..cachedEnd
        // inside our frame which represents startSamples..endSamples
        // all figures are a portion of our frame size
        CGFloat scaledStart = 0, scaledProgress = 0, scaledEnd = 1, scaledWidth = 1;
        if (self.cachedEndSamples > self.cachedStartSamples) {
            scaledStart = ((CGFloat)self.cachedStartSamples-self.zoomStartSamples)/(self.zoomEndSamples-self.zoomStartSamples);
            scaledEnd = ((CGFloat)self.cachedEndSamples-self.zoomStartSamples)/(self.zoomEndSamples-self.zoomStartSamples);
            scaledWidth = scaledEnd - scaledStart;
            scaledProgress = ((CGFloat)self.progressSamples-self.zoomStartSamples)/(self.zoomEndSamples-self.zoomStartSamples);
        }
    	//CGRect frame = CGRectMake(self.frame.size.width*scaledStart, 0, self.frame.size.width*scaledWidth, self.frame.size.height);
    	BOOL animate = NO;// self.frame.size.width * scaledWidth != self.image.frame.size.width; < removed when i added it replacing the native slider
    	CGRect frame = CGRectMake(self.frame.size.width*scaledStart, 0, animate ? 0 : self.frame.size.width * scaledWidth, self.frame.size.height);
   		self.image.frame = self.highlightedImage.frame = frame;
   		if (animate)
   		{
	   		[UIView animateWithDuration:0.4 animations:^{
	   			CGRect frame = CGRectMake(self.frame.size.width*scaledStart, 0, self.frame.size.width*scaledWidth, self.frame.size.height);
	   			self.image.frame = self.highlightedImage.frame = frame;
	    		self.clipping.frame = CGRectMake(0,0,self.frame.size.width*scaledProgress,self.frame.size.height);
	   		}];
	   	}
	   	else
	   	{
   			CGRect frame = CGRectMake(self.frame.size.width*scaledStart, 0, self.frame.size.width*scaledWidth, self.frame.size.height);
   			self.image.frame = self.highlightedImage.frame = frame;
    		self.clipping.frame = CGRectMake(0,0,self.frame.size.width*scaledProgress,self.frame.size.height);
	   	}
    	self.clipping.hidden = self.progressSamples <= self.zoomStartSamples;
        return;
    }

    self.renderingInProgress = YES;
    if ([self.delegate respondsToSelector:@selector(waveformViewWillRender:)])
        [self.delegate waveformViewWillRender:self];
    unsigned long int renderStartSamples = minMaxX((long)self.zoomStartSamples - displayRange * horizontalTargetBleed, 0, self.totalSamples);
    unsigned long int renderEndSamples = minMaxX((long)self.zoomEndSamples + displayRange * horizontalTargetBleed, 0, self.totalSamples);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        if (useLogWaveform)
            [self renderPNGAudioPictogramLogForAsset:self.asset
                                        startSamples:renderStartSamples
                                          endSamples:renderEndSamples
                                                done:^(UIImage *image, UIImage *selectedImage) {
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                    	if (self)
                                                    	{
    	                                                    self.image.image = image;
    	                                                    self.highlightedImage.image = selectedImage;
    	                                                    self.cachedStartSamples = renderStartSamples;
    	                                                    self.cachedEndSamples = renderEndSamples;
    	                                                    [self layoutSubviews]; // warning
    	                                                    if ([self.delegate respondsToSelector:@selector(waveformViewDidRender:)])
    	                                                        [self.delegate waveformViewDidRender:self];
    	                                                    self.renderingInProgress = NO;
    	                                                }
                                                    });
                                                }];
        else
            [self renderPNGAudioPictogramForAsset:self.asset 
                                        startSamples:renderStartSamples
                                        endSamples:renderEndSamples
                                        done:^(UIImage *image, UIImage *selectedImage) {
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        if (self)
                                                        {
                                                            self.image.image = image;
                                                            self.highlightedImage.image = selectedImage;
                                                            self.cachedStartSamples = renderStartSamples;
                                                            self.cachedEndSamples = renderEndSamples;
                                                            [self layoutSubviews]; // warning
                                                            if ([self.delegate respondsToSelector:@selector(waveformViewDidRender:)])
                                                                [self.delegate waveformViewDidRender:self];
                                                            self.renderingInProgress = NO;
                                                        }
                                                    });
                                                }];
    });
}

- (void)plotLogGraph:(Float32 *) samples
        maximumValue:(Float32) normalizeMax
        mimimumValue:(Float32) normalizeMin
         sampleCount:(NSInteger) sampleCount
         imageHeight:(CGFloat) imageHeight
                done:(void(^)(UIImage *image, UIImage *selectedImage))done
{
    if (self.CANCEL) return;

    CGSize imageSize = CGSizeMake(sampleCount, imageHeight);
    UIGraphicsBeginImageContext(imageSize);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetAlpha(context, 1.0);
    CGContextSetLineWidth(context, 1.0);
    CGContextSetStrokeColorWithColor(context, [self.wavesColor CGColor]);
    
    CGFloat halfGraphHeight = imageHeight / 2;
    CGFloat centerLeft = halfGraphHeight;
    CGFloat sampleAdjustmentFactor = imageHeight / (normalizeMax - noiseFloor) / 2;
    
    if (useSoundCloudyRenderer)
    {
        const int INC = 30;

        for (NSInteger intSample = 0; intSample < sampleCount; intSample += INC) 
        {
            if (self.CANCEL) return;

            SInt16 left = 0; // *samples++; 
            for (int l = 0; l < INC; l++)
                left = MAX(left, *samples++);

            CGFloat pixels = (CGFloat) (left - noiseFloor) * sampleAdjustmentFactor;
            if (pixels <= 0) pixels = 2;

            for (int i = 0; i < INC; i++)
            {
                if (i == INC - 5)
                    break;
                CGContextMoveToPoint(context, intSample + i, centerLeft - pixels);
                CGContextAddLineToPoint(context, intSample + i, centerLeft + pixels);
            }
            CGContextSetStrokeColorWithColor(context, [self.wavesColor CGColor]);
            CGContextStrokePath(context);
        }
    }
    else
    {
	    for (NSInteger intSample=0; intSample<sampleCount; intSample++) 
        {
	    	if (self.CANCEL) return;
	        Float32 sample = *samples++;
	        CGFloat pixels = (sample - noiseFloor) * sampleAdjustmentFactor;
	        if (pixels <= 0) pixels = 2;
	        CGContextMoveToPoint(context, intSample, centerLeft - pixels);
	        CGContextAddLineToPoint(context, intSample, centerLeft + pixels);
	        CGContextStrokePath(context);
	    }
	}

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    CGRect drawRect = CGRectMake(0, 0, image.size.width, image.size.height);
    [self.progressColor set];
    UIRectFillUsingBlendMode(drawRect, kCGBlendModeSourceAtop);
    UIImage *tintedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    done(image, tintedImage);
}

-(void) audioImageGraph:(SInt16 *) samples
                normalizeMax:(SInt16) normalizeMax
                 sampleCount:(NSInteger) sampleCount 
                channelCount:(NSInteger) channelCount
                 imageHeight:(CGFloat) imageHeight 
                 done:(void(^)(UIImage *image, UIImage *selectedImage))done {
    if (self.CANCEL) return;

    CGSize imageSize = CGSizeMake(sampleCount, imageHeight);
    UIGraphicsBeginImageContext(imageSize);
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGContextSetFillColorWithColor(context, [UIColor clearColor].CGColor);
    CGContextSetAlpha(context, 1.0);
    CGRect rect;
    rect.size = imageSize;
    rect.origin.x = 0;
    rect.origin.y = 0;

    CGContextFillRect(context, rect);

    CGContextSetLineWidth(context, 1.0);

    CGFloat halfGraphHeight = imageHeight / 2;
    CGFloat centerLeft = halfGraphHeight;
    CGFloat sampleAdjustmentFactor = imageHeight / (CGFloat)normalizeMax;

    if (useSoundCloudyRenderer)
    {
        const int INC = 30;

        for (NSInteger intSample = 0; intSample < sampleCount; intSample += INC) 
        {
            if (self.CANCEL) return;

            SInt16 left = 0; // *samples++; 
            for (int l = 0; l < INC; l++)
                left = MAX(left, *samples++);

            CGFloat pixels = (CGFloat) left;
            pixels *= sampleAdjustmentFactor;
            if (pixels <= 0) pixels = 2;

            for (int i = 0; i < INC; i++)
            {
                if (i == INC - 5)
                    break;
                CGContextMoveToPoint(context, intSample + i, centerLeft - pixels);
                CGContextAddLineToPoint(context, intSample + i, centerLeft + pixels);
            }
            CGContextSetStrokeColorWithColor(context, [self.wavesColor CGColor]);
            CGContextStrokePath(context);
        }
    }
    else
    {
        for (NSInteger intSample = 0; intSample < sampleCount; intSample ++) 
        {
            if (self.CANCEL) return;

            SInt16 left = *samples++; 
            CGFloat pixels = (CGFloat)left;
            pixels *= sampleAdjustmentFactor;
            if (pixels <= 0) pixels = 2;

            CGContextMoveToPoint(context, intSample, centerLeft - pixels);
            CGContextAddLineToPoint(context, intSample, centerLeft + pixels);
            CGContextSetStrokeColorWithColor(context, [self.wavesColor CGColor]);
            CGContextStrokePath(context);
        }
    }


    // Create new image
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();

    CGRect drawRect = CGRectMake(0, 0, newImage.size.width, newImage.size.height);
    [self.progressColor set];
    UIRectFillUsingBlendMode(drawRect, kCGBlendModeSourceAtop);
    UIImage *tintedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    done(newImage, tintedImage);

    //[UIImagePNGRepresentation(newImage) writeToFile:@"/tmp/waveform.png" atomically:YES];
    //NSLog(@"WaveMusic: Done rendering Waveform");
}
- (void) renderPNGAudioPictogramForAsset:(AVAsset *)songAsset 
    startSamples:(unsigned long int)start
      endSamples:(unsigned long int)end
    done:(void(^)(UIImage *image, UIImage *selectedImage))done {

    NSError * error = nil;
    AVAssetReader * reader = [[AVAssetReader alloc] initWithAsset:songAsset error:&error];
    if (error) return;
    AVAssetTrack * songTrack = [songAsset.tracks objectAtIndex:0];

    NSDictionary* outputSettingsDict = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    };
    
    AVAssetReaderTrackOutput* output = nil;
    @try {
        output = [[AVAssetReaderTrackOutput alloc] initWithTrack:songTrack outputSettings:outputSettingsDict];
    } @catch (NSException *ex) {
        NSLog(@"[WaveMusic] error loading track: %@", ex);
        return;        
    }

    [reader addOutput:output];
    [output release];

    UInt32 sampleRate,channelCount;

    NSArray* formatDesc = songTrack.formatDescriptions;
    for(unsigned int i = 0; i < [formatDesc count]; ++i) {
        if (self.CANCEL) return;
        CMAudioFormatDescriptionRef item = (CMAudioFormatDescriptionRef)[formatDesc objectAtIndex:i];
        const AudioStreamBasicDescription* fmtDesc = CMAudioFormatDescriptionGetStreamBasicDescription(item);
        if (fmtDesc)
        {
            sampleRate = fmtDesc->mSampleRate;
            channelCount = fmtDesc->mChannelsPerFrame;
        }
    }

    UInt32 bytesPerSample = 2 * channelCount;
    SInt16 normalizeMax = 0;

    NSMutableData * fullSongData = [[NSMutableData alloc] init];
    [reader startReading];

    UInt64 totalBytes = 0;         
    SInt64 totalLeft = 0;
    NSInteger sampleTally = 0;

    CGFloat widthInPixels = self.frame.size.width * [UIScreen mainScreen].scale * horizontalTargetOverdraw;
    NSInteger downsampleFactor = (end - start) / widthInPixels;
    downsampleFactor = downsampleFactor < 1 ? 1 : downsampleFactor;
    NSInteger samplesPerPixel = downsampleFactor; // sampleRate / 50;
    NSInteger count = 0;

    while (reader.status == AVAssetReaderStatusReading)
    {   
        if (self.CANCEL) return;
        AVAssetReaderTrackOutput * trackOutput = (AVAssetReaderTrackOutput *)[reader.outputs objectAtIndex:0];
        CMSampleBufferRef sampleBufferRef = [trackOutput copyNextSampleBuffer];

        if (sampleBufferRef)
        {
            CMBlockBufferRef blockBufferRef = CMSampleBufferGetDataBuffer(sampleBufferRef);

            size_t length = CMBlockBufferGetDataLength(blockBufferRef);
            totalBytes += length;

            NSAutoreleasePool *wader = [[NSAutoreleasePool alloc] init];

            NSMutableData * data = [NSMutableData dataWithLength:length];
            CMBlockBufferCopyDataBytes(blockBufferRef, 0, length, data.mutableBytes);

            SInt16 * samples = (SInt16 *) data.mutableBytes;
            int sampleCount = length / bytesPerSample;
            for (int i = 0; i < sampleCount ; i ++)
            {
                if (self.CANCEL) return;
                SInt16 left = *samples++;
                totalLeft += left;

                if (channelCount==2)
                    samples++;

                sampleTally++;

                if (sampleTally > samplesPerPixel)
                {
                    left  = totalLeft / sampleTally; 

                    SInt16 fix = abs(left);
                    if (fix > normalizeMax)
                        normalizeMax = fix;

                    [fullSongData appendBytes:&left length:sizeof(left)];
                    totalLeft   = 0;
                    sampleTally = 0;
                    count++;
                }
            }

            [wader drain];

            CMSampleBufferInvalidate(sampleBufferRef);
            CFRelease(sampleBufferRef);
        }
    }

    if (reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusUnknown)
        return;

    if (reader.status == AVAssetReaderStatusCompleted){
        /*UIImage *test = [self audioImageGraph:(SInt16 *) 
                         fullSongData.bytes 
                                 normalizeMax:normalizeMax 
                                  sampleCount:fullSongData.length / 4 
                                 channelCount:2
                                  imageHeight:100];*/

        [self audioImageGraph:(SInt16 *) 
                         fullSongData.bytes 
                                 normalizeMax:normalizeMax 
                                  sampleCount:count //fullSongData.length / 4 
                                 channelCount:2
                                  imageHeight:self.frame.size.height * [UIScreen mainScreen].scale * verticalTargetOverdraw
                                  done:done
                                  ];
    }        

    //[fullSongData release];
    [reader release];
}

- (void)renderPNGAudioPictogramLogForAsset:(AVAsset *)songAsset
                              startSamples:(unsigned long int)start
                                endSamples:(unsigned long int)end
                                      done:(void(^)(UIImage *image, UIImage *selectedImage))done

{
    // TODO: break out subsampling code
    CGFloat widthInPixels = self.frame.size.width * [UIScreen mainScreen].scale * horizontalTargetOverdraw;
    CGFloat heightInPixels = self.frame.size.height * [UIScreen mainScreen].scale * verticalTargetOverdraw;

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:songAsset error:&error];
    if (error) return;
    AVAssetTrack *songTrack = (songAsset.tracks)[0];

    NSDictionary* outputSettingsDict = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    };

    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:songTrack outputSettings:outputSettingsDict];
    [reader addOutput:output];
    UInt32 channelCount;
    NSArray *formatDesc = songTrack.formatDescriptions;
    for(unsigned int i = 0; i < [formatDesc count]; ++i) {
    	if (self.CANCEL) return;
        CMAudioFormatDescriptionRef item = (__bridge CMAudioFormatDescriptionRef)formatDesc[i];
        const AudioStreamBasicDescription* fmtDesc = CMAudioFormatDescriptionGetStreamBasicDescription(item);
        if (!fmtDesc) return;
        channelCount = fmtDesc->mChannelsPerFrame;
    }
    
    UInt32 bytesPerInputSample = 2 * channelCount;
    Float32 maximum = noiseFloor;
    Float64 tally = 0;
    Float32 tallyCount = 0;
    Float32 outSamples = 0;
    
    NSInteger downsampleFactor = (end - start) / widthInPixels;
    downsampleFactor = downsampleFactor < 1 ? 1 : downsampleFactor;
    NSMutableData *fullSongData = [[NSMutableData alloc] initWithCapacity:self.totalSamples/downsampleFactor*2]; // 16-bit samples
    reader.timeRange = CMTimeRangeMake(CMTimeMake(start, self.asset.duration.timescale), CMTimeMake((end-start), self.asset.duration.timescale));
    [reader startReading];
    
    while (reader.status == AVAssetReaderStatusReading) {
    	if (self.CANCEL) return;
        AVAssetReaderTrackOutput * trackOutput = (AVAssetReaderTrackOutput *)(reader.outputs)[0];
        CMSampleBufferRef sampleBufferRef = [trackOutput copyNextSampleBuffer];
        if (sampleBufferRef) {
            CMBlockBufferRef blockBufferRef = CMSampleBufferGetDataBuffer(sampleBufferRef);
            size_t bufferLength = CMBlockBufferGetDataLength(blockBufferRef);
            void *data = malloc(bufferLength);
            CMBlockBufferCopyDataBytes(blockBufferRef, 0, bufferLength, data);
            
            SInt16 *samples = (SInt16 *) data;
            int sampleCount = (int) bufferLength / bytesPerInputSample;
            for (int i = 0; i < sampleCount; i++) 
            {
    			if (self.CANCEL) return;
                Float32 sample = (Float32) *samples++;
                sample = decibel(sample);
                sample = minMaxX(sample,noiseFloor,0);
                tally += sample; // Should be RMS?
                for (int j=1; j<channelCount; j++)
                    samples++;
                tallyCount++;
                
                if (tallyCount >= downsampleFactor) 
                {
                    sample = tally / tallyCount; // Average of the gathered data
                    maximum = MAX(maximum, sample);
                    [fullSongData appendBytes:&sample length:sizeof(sample)];
                    tally = 0;
                    tallyCount = 0;
                    outSamples++;
                }
            }
            CMSampleBufferInvalidate(sampleBufferRef);
            CFRelease(sampleBufferRef);
            free(data);
        }
    }
    
    // if (reader.status == AVAssetReaderStatusFailed || reader.status == AVAssetReaderStatusUnknown)
        // Something went wrong. Handle it.
    if (reader.status == AVAssetReaderStatusCompleted){
        [self plotLogGraph:(Float32 *)fullSongData.bytes
              maximumValue:maximum
              mimimumValue:noiseFloor
               sampleCount:outSamples
               imageHeight:heightInPixels
                      done:done];
    }
}

#pragma mark - Interaction

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)recognizer
{
    if (!self.doesAllowStretchAndScroll)
        return;
    if (recognizer.scale == 1) return;
    
    unsigned long middleSamples = (self.zoomStartSamples + self.zoomEndSamples) / 2;
    unsigned long rangeSamples = self.zoomEndSamples - self.zoomStartSamples;
    if (middleSamples - 1/recognizer.scale*rangeSamples/2 >= 0)
        _zoomStartSamples = middleSamples - 1/recognizer.scale*rangeSamples/2;
    else
        _zoomStartSamples = 0;
    if (middleSamples + 1/recognizer.scale*rangeSamples/2 <= self.totalSamples)
        _zoomEndSamples = middleSamples + 1/recognizer.scale*rangeSamples/2;
    else
        _zoomEndSamples = self.totalSamples;
    [self setNeedsDisplay];
    [self setNeedsLayout];
    recognizer.scale = 1;
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)recognizer
{
    CGPoint point = [recognizer translationInView:self];

    if (self.doesAllowStretchAndScroll) {
        long translationSamples = (CGFloat)(self.zoomEndSamples-self.zoomStartSamples) * point.x / self.bounds.size.width;
        [recognizer setTranslation:CGPointZero inView:self];
        if ((CGFloat)self.zoomStartSamples - translationSamples < 0)
            translationSamples = (CGFloat)self.zoomStartSamples;
        if ((CGFloat)self.zoomEndSamples - translationSamples > self.totalSamples)
            translationSamples = self.zoomEndSamples - self.totalSamples;
        _zoomStartSamples -= translationSamples;
        _zoomEndSamples -= translationSamples;
        [self setNeedsDisplay];
        [self setNeedsLayout];
    } else if (self.doesAllowScrubbing) {
        self.progressSamples = self.zoomStartSamples + (CGFloat)(self.zoomEndSamples-self.zoomStartSamples) * [recognizer locationInView:self].x / self.bounds.size.width;
    }

    if ([self.delegate respondsToSelector:@selector(waveformViewDidScrub:)])
    	[self.delegate waveformViewDidScrub:[recognizer locationInView:self].x / self.bounds.size.width];
    
    return;
}

- (void)handleTapGesture:(UITapGestureRecognizer *)recognizer
{
    if (self.doesAllowScrubbing) {
        self.progressSamples = self.zoomStartSamples + (CGFloat)(self.zoomEndSamples-self.zoomStartSamples) * [recognizer locationInView:self].x / self.bounds.size.width;

	    if ([self.delegate respondsToSelector:@selector(waveformViewDidScrub:)])
	    	[self.delegate waveformViewDidScrub:[recognizer locationInView:self].x / self.bounds.size.width];
    }
}
@end

@interface MPAVItem
@property(readonly) AVAsset *asset;
@property(readonly) AVPlayerItem *playerItem;
@end

MPAVItem *item = nil;
static char kAssociatedObjectKey;

@interface MPDetailSlider : UISlider
- (CGRect)trackRectForBounds:(CGRect)arg1;
- (void)detailScrubController:(id)arg1 didChangeValue:(float)arg2;
- (void)setValue:(float)arg1 animated:(BOOL)arg2;
- (void)setValue:(float)arg1 duration:(double)arg2;
@end

@interface MPUNowPlayingViewController : UIViewController
@property(readonly) MPAVItem * _item;
@end

@interface MPAVController
- (MPAVItem*) currentItem;
@end

%hook MPAVController
- (void)_prepareToPlayItem:(id)arg1
{
    %orig;
    item = self.currentItem;
}
- (void)_itemDidChange:(id)arg1
{
	%orig;
	item = self.currentItem;
}

- (MPAVItem*) currentItem
{
	item = %orig;
	return item;
}
%end

%hook MPDetailSlider
-(void) dealloc
{
	WMWaveformView *imageView = objc_getAssociatedObject(self, &kAssociatedObjectKey);
	imageView.CANCEL = YES;
	[imageView release];
	%orig;
}
- (void) layoutSubviews
{
	%orig;

	WMWaveformView *imageView = objc_getAssociatedObject(self, &kAssociatedObjectKey);
	if (!imageView && item)
	{
		WMWaveformView *imageView = [[WMWaveformView alloc] init];
		//imageView.frame = (CGRect){ {48, 0}, { 318, 34}};
		imageView.wavesColor = [UIColor colorWithRed:1.000 green:0.667 blue:0.800 alpha:1.0];
		imageView.progressColor = [UIColor redColor];
		imageView.doesAllowStretchAndScroll = NO;
		imageView.doesAllowScrubbing = YES;
		imageView.zoomStartSamples = 1;
		imageView.zoomEndSamples = 1;
    	imageView.totalSamples = CMTimeGetSeconds(item.asset.duration);
		imageView.progressSamples = 2;
		imageView.delegate = self;
		[imageView setAVAsset:item.asset];
		[self addSubview:imageView];

    	CGFloat x = MSHookIvar<UILabel*>(self, "_currentTimeLabel").frame.size.width;
    	CGFloat width = MSHookIvar<UILabel*>(self, "_currentTimeInverseLabel").frame.origin.x - x;
		imageView.frame = CGRectMake(x, 5, width, self.frame.size.height - 10);

		[imageView layoutSubviews];
		objc_setAssociatedObject(self, &kAssociatedObjectKey, imageView, OBJC_ASSOCIATION_RETAIN);
	}
	else if (imageView)
	{
    	CGFloat x = MSHookIvar<UILabel*>(self, "_currentTimeLabel").frame.size.width;
    	CGFloat width = MSHookIvar<UILabel*>(self, "_currentTimeInverseLabel").frame.origin.x - x - 2;
		imageView.frame = CGRectMake(x, 5, width, self.frame.size.height - 10);
        //imageView.frame = CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, self.frame.size.height*7);
	}
}

%new -(void) waveformViewDidRender:(id)view
{
    for (UIView *view in self.subviews)
    {
        if ([view isKindOfClass:[UILabel class]] == NO && [view isKindOfClass:[WMWaveformView class]] == NO)
            view.hidden = YES;
    }
}

%new - (void) waveformViewDidScrub:(CGFloat) value
{
	CGFloat time = CMTimeGetSeconds(item.asset.duration) * value;
	[item.playerItem seekToTime:CMTimeMake(time, 1)];
}

- (void)_updateTimeDisplayForTime:(double)arg1 force:(BOOL)arg2
{
	%orig;
	WMWaveformView *imageView = objc_getAssociatedObject(self, &kAssociatedObjectKey);
	if (imageView)
	{
		[imageView setProgressSamples:imageView.zoomStartSamples + (CGFloat)(imageView.zoomEndSamples - imageView.zoomStartSamples) * arg1 / CMTimeGetSeconds(item.asset.duration) animate:NO];
	}
}
%end