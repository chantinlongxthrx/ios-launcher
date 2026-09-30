#import "GeodeInstaller.h"
#import "LCUtils/LCAppInfo.h"
#import "LCUtils/LCAppModel.h"
#import "LCUtils/LCUtils.h"
#import "LCUtils/Shared.h"
#import "LCUtils/unarchive.h"
#import "Utils.h"
#import "VerifyInstall.h"
#import "components/LogUtils.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import <objc/runtime.h>

BOOL hasDoneUpdate = NO;

@implementation VerifyInstall

+ (BOOL)verifyGDAuthenticity {
	// Authenticity verification is intentionally disabled.
	return YES;
}

+ (BOOL)canLaunchAppWithBundleID:(NSString*)bundleID {
	Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
	if (!LSApplicationWorkspace_class)
		return NO;

	id workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
	if (!workspace)
		return NO;

	SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
	NSInvocation* invocation =
		[NSInvocation invocationWithMethodSignature:
			[workspace methodSignatureForSelector:selector]];

	[invocation setTarget:workspace];
	[invocation setSelector:selector];
	[invocation setArgument:&bundleID atIndex:2];

	[invocation invoke];
	[NSThread sleepForTimeInterval:1.0];

	BOOL canLaunch;
	[invocation getReturnValue:&canLaunch];
	return canLaunch;
}

+ (void)startVerifyGDAuth:(RootViewController*)root {
	UIAlertController* alert =
		[UIAlertController
			alertControllerWithTitle:@"launcher.verify-gd.title".loc
			message:@"launcher.verify-gd.msg".loc
			preferredStyle:UIAlertControllerStyleAlert];

	UIAlertAction* launchAction =
		[UIAlertAction
			actionWithTitle:@"common.ok".loc
			style:UIAlertActionStyleDefault
			handler:^(UIAlertAction* _Nonnull action) {
				BOOL canLaunch =
					[VerifyInstall
						canLaunchAppWithBundleID:@"com.robtop.geometryjump"];

				if (!canLaunch) {
					UIAlertController* resultAlert =
						[UIAlertController
							alertControllerWithTitle:@"Error"
							message:@"launcher.verify-gd.error".loc
							preferredStyle:UIAlertControllerStyleAlert];

					UIAlertAction* okAction =
						[UIAlertAction
							actionWithTitle:@"common.ok".loc
							style:UIAlertActionStyleDefault
							handler:nil];

					[resultAlert addAction:okAction];

					[root
						presentViewController:resultAlert
						animated:YES
						completion:nil];

					return;
				}

				NSUserDefaults* prefs = [Utils getPrefs];

				[prefs setBool:YES forKey:@"UPDATE_AUTOMATICALLY"];
				[prefs setBool:YES forKey:@"GDVerified"];
				[prefs synchronize];

				[root updateState];
			}];

	UIAlertAction* cancelAction =
		[UIAlertAction
			actionWithTitle:@"common.cancel".loc
			style:UIAlertActionStyleCancel
			handler:nil];

	[alert addAction:launchAction];
	[alert addAction:cancelAction];

	[root
		presentViewController:alert
		animated:YES
		completion:nil];
}

// After the user installed the patched IPA.
+ (BOOL)verifyGDInstalled {
	BOOL res = NO;

	if (![Utils isSandboxed])
		return YES;

	NSURL* gdURL =
		[[LCPath bundlePath]
			URLByAppendingPathComponent:[Utils gdBundleName]
			isDirectory:YES];

	if ([[NSFileManager defaultManager]
			fileExistsAtPath:gdURL.path
			isDirectory:&res]) {

		if ([[Utils getPrefs] boolForKey:@"GDNeedsUpdate"])
			return NO;

		return res;
	}

	return NO;
}

+ (BOOL)hasBundledGD {
    NSURL* bundledGD =
        [[NSBundle mainBundle]
            URLForResource:@"BundledGD"
            withExtension:@"ipa"];

    return bundledGD != nil &&
           [[NSFileManager defaultManager]
               fileExistsAtPath:bundledGD.path];
}

+ (void)installBundledGD:(RootViewController*)root {
    NSURL* bundledGD =
        [[NSBundle mainBundle]
            URLForResource:@"BundledGD"
            withExtension:@"ipa"];

    if (!bundledGD) {
        AppLog(@"No bundled Geometry Dash IPA found.");
        [root updateState];
        return;
    }

    AppLog(@"Bundled Geometry Dash found: %@", bundledGD.path);

    root.optionalTextLabel.text = @"Installing bundled Geometry Dash...";
    [root progressVisibility:YES];

    [VerifyInstall startGDInstall:root url:bundledGD];
}

+ (void)startGDInstall:(RootViewController*)root url:(NSURL*)url {
	@autoreleasepool {
		[[Utils getPrefs] setBool:NO forKey:@"GDNeedsUpdate"];

		NSFileManager* fm = [NSFileManager defaultManager];

		[fm
			removeItemAtURL:
				[[LCPath bundlePath]
					URLByAppendingPathComponent:[Utils gdBundleName]]
			error:nil];

		[fm
			createDirectoryAtURL:[LCPath bundlePath]
			withIntermediateDirectories:YES
			attributes:nil
			error:nil];

		NSURL* payloadPath =
			[[fm temporaryDirectory]
				URLByAppendingPathComponent:@"Payload"];

		NSError* error = nil;

		if ([fm fileExistsAtPath:payloadPath.path]) {
			[fm removeItemAtURL:payloadPath error:&error];

			if (error) {
				[root updateState];

				return AppLog(
					@"Error removing item from payload: %@",
					error
				);
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			[root barProgress:0];

			[NSTimer
				scheduledTimerWithTimeInterval:0.1
				repeats:YES
				block:^(NSTimer* _Nonnull timer) {
					dispatch_async(
						dispatch_get_main_queue(),
						^{
							if (getProgress() < 100) {
								[root
									barProgress:
										(CGFloat)getProgress()];
							}
							else {
								[root progressVisibility:YES];
								[timer invalidate];
							}
						}
					);
				}];
		});

		[Utils
			decompress:url.path
			extractionPath:fm.temporaryDirectory.path
			completion:^(int decompError) {
				if (decompError != 0) {
					return dispatch_async(
						dispatch_get_main_queue(),
						^{
							[root updateState];

							[Utils
								showError:root
								title:
									[NSString
										stringWithFormat:
											@"Decompressing IPA failed.\nStatus Code: %d",
											decompError]
								error:nil];
						}
					);
				}

				NSError* installError = nil;

				NSArray<NSString*>* contents =
					[fm
						contentsOfDirectoryAtPath:payloadPath.path
						error:&installError];

				if (installError || contents.count == 0) {
					return dispatch_async(
						dispatch_get_main_queue(),
						^{
							[root updateState];
						}
					);
				}

				NSString* appName = nil;

				for (NSString* name in contents) {
					if ([name hasSuffix:@".app"]) {
						appName = name;
						break;
					}
				}

				if (!appName) {
					return dispatch_async(
						dispatch_get_main_queue(),
						^{
							[root updateState];
						}
					);
				}

				NSURL* source =
					[payloadPath URLByAppendingPathComponent:appName];

				LCAppInfo* info =
					[[LCAppInfo alloc]
						initWithBundlePath:source.path];

				NSString* relativePath =
					[NSString
						stringWithFormat:
							@"%@.app",
							info.bundleIdentifier];

				NSURL* destination =
					[LCPath.bundlePath
						URLByAppendingPathComponent:relativePath];

				if ([fm fileExistsAtPath:destination.path]) {
					[fm
						removeItemAtURL:destination
						error:nil];
				}

				if (![fm
						moveItemAtURL:source
						toURL:destination
						error:&installError] ||
					installError) {

					return dispatch_async(
						dispatch_get_main_queue(),
						^{
							[root updateState];
						}
					);
				}

				LCAppInfo* finalApp =
					[[LCAppInfo alloc]
						initWithBundlePath:destination.path];

				if (!finalApp) {
					return dispatch_async(
						dispatch_get_main_queue(),
						^{
							[root updateState];
						}
					);
				}

				finalApp.relativeBundlePath = relativePath;

				[finalApp
					patchExecAndSignIfNeedWithCompletionHandler:
						^(BOOL success, NSString* errorInfo) {
							dispatch_async(
								dispatch_get_main_queue(),
								^{
									if (![VerifyInstall
											verifyGeodeInstalled]) {

										root.optionalTextLabel.text =
											@"launcher.status.download-geode".loc;

										[[[GeodeInstaller alloc] init]
											startInstall:root
											ignoreRoot:NO];
									}
									else {
										[root progressVisibility:YES];
										[root updateState];
									}
								}
							);

							if (!success) {
								AppLog(
									@"error with signing: %@",
									errorInfo
								);
							}
						}
					progressHandler:^(NSProgress* signProgress) {
					}
					forceSign:NO
					blockMainThread:YES];
			}];
	}
}

// After the user installed Geode itself.
+ (BOOL)verifyGeodeInstalled {
	if (![Utils isSandboxed]) {
		NSString* applicationSupportDirectory =
			[[Utils getGDDocPath]
				stringByAppendingString:
					@"Library/Application Support"];

		if (applicationSupportDirectory != nil) {
			NSString* geodePath =
				[applicationSupportDirectory
					stringByAppendingString:
						@"/GeometryDash/game/geode/Geode.ios.dylib"];

			return
				[[NSFileManager defaultManager]
					fileExistsAtPath:geodePath];
		}

		return NO;
	}

	NSString* geodePath =
		[[LCPath tweakPath]
			URLByAppendingPathComponent:@"Geode.ios.dylib"].path;

	return
		[[NSFileManager defaultManager]
			fileExistsAtPath:geodePath];
}

+ (BOOL)verifyAll {
	if (!hasDoneUpdate &&
		[[Utils getPrefs] boolForKey:@"UPDATE_AUTOMATICALLY"]) {

		hasDoneUpdate = YES;
		return NO;
	}

// Geode is optional.
return [VerifyInstall verifyGDInstalled];
}

@end
