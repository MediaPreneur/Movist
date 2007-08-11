//
//  Movist
//
//  Created by dckim <cocoable@gmail.com>
//  Copyright 2006 cocoable. All rights reserved.
//

#import "MMovie_QuickTime.h"

@implementation MTrack_QuickTime

- (id)initWithQTTrack:(QTTrack*)qtTrack
{
    TRACE(@"%s %@", __PRETTY_FUNCTION__, qtTrack);
    if (self = [super init]) {
        _qtTrack = [qtTrack retain];
    }
    return self;
}

- (void)dealloc
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_qtTrack release];
    [super dealloc];
}

- (NSString*)name
{
    return [_qtTrack attributeForKey:QTTrackDisplayNameAttribute];
}

- (NSString*)format
{
    NSString* result = @"";

    ImageDescriptionHandle idh;
    idh = (ImageDescriptionHandle)NewHandleClear(sizeof(ImageDescription));
    GetMediaSampleDescription([[_qtTrack media] quickTimeMedia], 1,
                              (SampleDescriptionHandle)idh);

    NSString* mediaType = [_qtTrack attributeForKey:QTTrackMediaTypeAttribute];
    if ([mediaType isEqualToString:QTMediaTypeVideo]) {
        CFStringRef summary;
        if (noErr == ICMImageDescriptionGetProperty(idh,
                        kQTPropertyClass_ImageDescription,
                        kICMImageDescriptionPropertyID_SummaryString,
                        sizeof(CFStringRef), &summary, 0)) {
            result = [NSString stringWithString:(NSString*)summary];
            CFRelease(summary);
            return result;
        }
    }
    else if ([mediaType isEqualToString:QTMediaTypeMPEG]) {
        NSRect rc = [[_qtTrack attributeForKey:QTTrackBoundsAttribute] rectValue];
        result = [NSString stringWithFormat:@"%@, %g x %g",
            /*FIXME*/[self name], rc.size.width, rc.size.height];
    }
    else if ([mediaType isEqualToString:QTMediaTypeSound]) {
        CFStringRef summary;
        if (noErr == ICMImageDescriptionGetProperty(idh,
                                                    kQTPropertyClass_ImageDescription,
                                                    kICMImageDescriptionPropertyID_SummaryString,
                                                    sizeof(CFStringRef), &summary, 0)) {
            TRACE(@"format: %@", (NSString*)summary);
            result = [NSString stringWithString:(NSString*)summary];
            CFRelease(summary);
            return result;
        }
    }
    DisposeHandle((Handle)idh);
    return result;

/*
    ImageDescriptionHandle idh;
    idh = (ImageDescriptionHandle)NewHandleClear(sizeof(ImageDescription));
    GetMediaSampleDescription([[_qtTrack media] quickTimeMedia], 1,
                              (SampleDescriptionHandle)idh);
    ImageDescription* desc = *idh;
    CodecInfo codecInfo;
    GetCodecInfo(&codecInfo, desc->cType, 0);
    DisposeHandle((Handle)desc);

    NSString* name = (codecInfo.typeName[0] == '\0') ? [self name] :
                        [NSString stringWithUTF8String:codecInfo.typeName];
*/
}

- (BOOL)isEnabled { return [_qtTrack isEnabled]; }
- (void)setEnabled:(BOOL)enabled { [_qtTrack setEnabled:enabled]; }
- (float)volume { return [_qtTrack volume]; }
- (void)setVolume:(float)volume { [_qtTrack setVolume:volume]; }

@end

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

@implementation MMovie_QuickTime

- (id)initWithURL:(NSURL*)url error:(NSError**)error
{
    TRACE(@"%s %@", __PRETTY_FUNCTION__, [url absoluteString]);
    if ((self = [super initWithURL:url error:error])) {
        if ([url isFileURL]) {
            _qtMovie = [[QTMovie movieWithFile:[url path] error:error] retain];
        }
        else {
            _qtMovie = [[QTMovie movieWithURL:url error:error] retain];
        }
        if (!_qtMovie) {
            [self release];
            return nil;
        }
        // init video tracks
        QTTrack* track;
        NSString* mediaType;
        NSArray* tracks = [_qtMovie tracks];
        NSEnumerator* enumerator = [tracks objectEnumerator];
        while (track = [enumerator nextObject]) {
            mediaType = [track attributeForKey:QTTrackMediaTypeAttribute];
            if ([mediaType isEqualToString:QTMediaTypeVideo] ||
                [mediaType isEqualToString:QTMediaTypeMPEG]/* ||
                [mediaType isEqualToString:QTMediaTypeMovie]*/) {
                [_videoTracks addObject:[[[MTrack_QuickTime alloc]
                                        initWithQTTrack:track] autorelease]];
            }
            else if ([mediaType isEqualToString:QTMediaTypeSound]/* ||
                     [mediaType isEqualToString:QTMediaTypeMusic]*/) {
                [_audioTracks addObject:[[[MTrack_QuickTime alloc]
                                        initWithQTTrack:track] autorelease]];
            }
        }
    }
    return self;
}

- (BOOL)setOpenGLContext:(NSOpenGLContext*)openGLContext
             pixelFormat:(NSOpenGLPixelFormat*)openGLPixelFormat
                   error:(NSError**)error
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    // create visual context
    OSStatus ret = QTOpenGLTextureContextCreate(kCFAllocatorDefault,
                                                [openGLContext CGLContextObj],
                                                [openGLPixelFormat CGLPixelFormatObj],
                                                0, &_visualContext);
    if (ret != noErr) {
        TRACE(@"QTOpenGLTextureContextCreate() failed: %d", ret);
        if (error) {
            NSDictionary* dict =
            [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:ret]
                                        forKey:@"returnCode"];
            *error = [NSError errorWithDomain:@"QuickTime"
                                         code:ERROR_VISUAL_CONTEXT_CREATE_FAILED
                                     userInfo:dict];
        }
        return FALSE;
    }

    SetMovieVisualContext([_qtMovie quickTimeMovie], _visualContext);

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(qtMovieRateChanged:)
               name:QTMovieRateDidChangeNotification object:_qtMovie];
    [nc addObserver:self selector:@selector(qtMovieEnded:)
               name:QTMovieDidEndNotification object:_qtMovie];
    return TRUE;
}

- (void)cleanup
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    SetMovieVisualContext([_qtMovie quickTimeMovie], 0);
    if (_visualContext) {
        CFRelease(_visualContext);
    }
    [_qtMovie release], _qtMovie = nil;
    [super cleanup];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (float)duration
{
    QTTime t = [_qtMovie duration];
    return (float)t.timeValue / t.timeScale;
}

- (NSSize)size
{
    return [[_qtMovie attributeForKey:QTMovieNaturalSizeAttribute] sizeValue];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark volume

- (float)preferredVolume
{
    return [[_qtMovie attributeForKey:QTMoviePreferredVolumeAttribute] floatValue];
}

- (float)volume { return [_qtMovie volume]; }
- (BOOL)muted   { return [_qtMovie muted]; }

- (void)setVolume:(float)volume
{
    TRACE(@"%s %g", __PRETTY_FUNCTION__, volume);
    [_qtMovie setVolume:volume];
}

- (void)setMuted:(BOOL)muted
{
    TRACE(@"%s \"%@\"", __PRETTY_FUNCTION__, muted ? @"muted" : @"unmuted");
    [_qtMovie setMuted:muted];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark playback

- (float)currentTime
{
    QTTime t = [_qtMovie currentTime];
    return (float)t.timeValue / t.timeScale;
}

- (float)rate { return [_qtMovie rate]; }

- (void)setRate:(float)rate
{
    TRACE(@"%s %g", __PRETTY_FUNCTION__, rate);
    [_qtMovie setRate:rate];
}

- (void)stepBackward
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_qtMovie stepBackward];
}

- (void)stepForward
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_qtMovie stepForward];
}

- (void)gotoBeginning
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_qtMovie gotoBeginning];
}

- (void)gotoEnd
{
    TRACE(@"%s", __PRETTY_FUNCTION__);
    [_qtMovie gotoEnd];
}

- (void)gotoTime:(float)time
{
    TRACE(@"%s %g", __PRETTY_FUNCTION__, time);
    QTTime t = [_qtMovie currentTime];    // to fill timeScale & flags
    t.timeValue = (long long)(time * t.timeScale);

    if (t.timeValue < 0) {
        [_qtMovie gotoBeginning];
    }
    else if ([_qtMovie duration].timeValue < t.timeValue) {
        [_qtMovie gotoEnd];
    }
    else {
        float rate = [_qtMovie rate];
        [_qtMovie setCurrentTime:t];
        [_qtMovie setRate:rate];   // play continue...
    }
}

- (CVOpenGLTextureRef)nextImage:(const CVTimeStamp*)timeStamp
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    if (!QTVisualContextIsNewImageAvailable(_visualContext, timeStamp)) {
        return 0;
    }

    CVOpenGLTextureRef image;
    OSStatus ret = QTVisualContextCopyImageForTime(_visualContext, 0, timeStamp, &image);
    if (ret != noErr || !image) {
        return 0;
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieCurrentTimeNotification object:self];
    return image;
}

- (void)idleTask
{
    QTVisualContextTask(_visualContext);
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark notifications

- (void)qtMovieRateChanged:(NSNotification*)notification
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieRateChangeNotification object:self];
}

- (void)qtMovieEnded:(NSNotification*)notification
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieEndNotification object:self];
}

@end