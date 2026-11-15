#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generator. Run from any cwd."""
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
project = root / "BiteLens.xcodeproj"
project.mkdir(exist_ok=True)
project_contents = '''// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {};
    objectVersion = 56;
    objects = {
        A00000000000000000000001 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; };
        A00000000000000000000002 = {isa = PBXBuildFile; fileRef = A00000000000000000000012; };
        A00000000000000000000003 = {isa = PBXBuildFile; fileRef = A00000000000000000000013; };
        A00000000000000000000004 = {isa = PBXBuildFile; productRef = A00000000000000000000061; };
        A00000000000000000000005 = {isa = PBXBuildFile; fileRef = A00000000000000000000017; };
        A00000000000000000000006 = {isa = PBXBuildFile; fileRef = A00000000000000000000018; };
        A00000000000000000000011 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppConfiguration.swift; sourceTree = "<group>"; };
        A00000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BiteLensApp.swift; sourceTree = "<group>"; };
        A00000000000000000000013 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OnboardingRoot.swift; sourceTree = "<group>"; };
        A00000000000000000000014 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BiteLens.app; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000015 = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = App/Config/Signing.xcconfig; sourceTree = SOURCE_ROOT; };
        A00000000000000000000016 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = App/Config/Info.plist; sourceTree = SOURCE_ROOT; };
        A00000000000000000000017 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MealCamera.swift; sourceTree = "<group>"; };
        A00000000000000000000018 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CaptureHome.swift; sourceTree = "<group>"; };
        A00000000000000000000090 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MealReviewViews.swift; sourceTree = "<group>"; };
        A00000000000000000000091 = {isa = PBXBuildFile; fileRef = A00000000000000000000090; };
        A00000000000000000000092 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DraftAnalysisSection.swift; sourceTree = "<group>"; };
        A00000000000000000000093 = {isa = PBXBuildFile; fileRef = A00000000000000000000092; };
        A00000000000000000000094 = {isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon; sourceTree = "<group>"; };
        A00000000000000000000095 = {isa = PBXBuildFile; fileRef = A00000000000000000000094; };
        A00000000000000000000096 = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
        A00000000000000000000097 = {isa = PBXBuildFile; fileRef = A00000000000000000000096; };
        A00000000000000000000098 = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
        A00000000000000000000099 = {isa = PBXBuildFile; fileRef = A00000000000000000000098; };
        A000000000000000000000A0 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HealthKitClient.swift; sourceTree = "<group>"; };
        A000000000000000000000A1 = {isa = PBXBuildFile; fileRef = A000000000000000000000A0; };
        A000000000000000000000A3 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ObservationViews.swift; sourceTree = "<group>"; };
        A000000000000000000000A4 = {isa = PBXBuildFile; fileRef = A000000000000000000000A3; };
        C00000000000000000000001 = {isa = PBXBuildFile; fileRef = C00000000000000000000002; };
        C00000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITestMode.swift; sourceTree = "<group>"; };
        A000000000000000000000A2 = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = App/Config/BiteLens.entitlements; sourceTree = SOURCE_ROOT; };
        A00000000000000000000020 = {isa = PBXGroup; children = (A00000000000000000000021, A00000000000000000000078, B00000000000000000000001, C00000000000000000000020, A00000000000000000000015, A00000000000000000000016, A00000000000000000000076, B00000000000000000000002, B00000000000000000000003, A000000000000000000000A2, A00000000000000000000022); sourceTree = "<group>"; };
        A00000000000000000000021 = {isa = PBXGroup; children = (A00000000000000000000011, A00000000000000000000012, A00000000000000000000013, A00000000000000000000017, A00000000000000000000018, A00000000000000000000074, A00000000000000000000090, A00000000000000000000092, A00000000000000000000094, A00000000000000000000098, A000000000000000000000A0, A000000000000000000000A3, C00000000000000000000002); path = App/BiteLens; sourceTree = "<group>"; };
        A00000000000000000000022 = {isa = PBXGroup; children = (A00000000000000000000014, A00000000000000000000077, B00000000000000000000005, C00000000000000000000013); name = Products; sourceTree = "<group>"; };
        A00000000000000000000030 = {
            isa = PBXNativeTarget;
            buildConfigurationList = A00000000000000000000051;
            buildPhases = (A00000000000000000000031, A00000000000000000000032, A00000000000000000000033, A0000000000000000000007D);
            buildRules = ();
            dependencies = (A0000000000000000000007F, B0000000000000000000000A);
            name = BiteLens;
            packageProductDependencies = (A00000000000000000000061);
            productName = BiteLens;
            productReference = A00000000000000000000014;
            productType = "com.apple.product-type.application";
        };
        A00000000000000000000031 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000001, A00000000000000000000002, A00000000000000000000003, A00000000000000000000005, A00000000000000000000006, A00000000000000000000070, A00000000000000000000091, A00000000000000000000093, A000000000000000000000A1, A000000000000000000000A4, C00000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000032 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000004); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000033 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000095, A00000000000000000000099); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000040 = {
            isa = PBXProject;
            attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {A00000000000000000000030 = {CreatedOnToolsVersion = 16.0; SystemCapabilities = {com.apple.ApplicationGroups.iOS = {enabled = 1; }; com.apple.HealthKit = {enabled = 1; }; }; }; A00000000000000000000079 = {CreatedOnToolsVersion = 27.2; }; B00000000000000000000010 = {CreatedOnToolsVersion = 27.2; SystemCapabilities = {com.apple.ApplicationGroups.iOS = {enabled = 1; }; }; }; C00000000000000000000030 = {CreatedOnToolsVersion = 16.0; TestTargetID = A00000000000000000000030; }; }; };
            buildConfigurationList = A00000000000000000000050;
            compatibilityVersion = "Xcode 14.0";
            developmentRegion = en;
            hasScannedForEncodings = 0;
            knownRegions = (en, Base);
            mainGroup = A00000000000000000000020;
            packageReferences = (A00000000000000000000060);
            productRefGroup = A00000000000000000000022;
            projectDirPath = "";
            projectRoot = "";
            targets = (A00000000000000000000030, A00000000000000000000079, B00000000000000000000010, C00000000000000000000030);
        };
        A00000000000000000000050 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000052, A00000000000000000000053); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000051 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000054, A00000000000000000000055); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000052 = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf; }; name = Debug; };
        A00000000000000000000053 = {isa = XCBuildConfiguration; buildSettings = {CLANG_ENABLE_MODULES = YES; SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; }; name = Release; };
        A00000000000000000000054 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                CODE_SIGN_ENTITLEMENTS = App/Config/BiteLens.entitlements;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens";
                PRODUCT_NAME = "$(TARGET_NAME)";
                REGISTER_APP_GROUPS = YES;
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Debug;
        };
        A00000000000000000000055 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                CODE_SIGN_ENTITLEMENTS = App/Config/BiteLens.entitlements;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens";
                PRODUCT_NAME = "$(TARGET_NAME)";
                REGISTER_APP_GROUPS = YES;
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Release;
        };
        A00000000000000000000060 = {isa = XCLocalSwiftPackageReference; relativePath = .; };
        A00000000000000000000061 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000060; productName = BiteLensCore; };
        A00000000000000000000070 = {isa = PBXBuildFile; fileRef = A00000000000000000000074; };
        A00000000000000000000071 = {isa = PBXBuildFile; fileRef = A00000000000000000000074; };
        A00000000000000000000072 = {isa = PBXBuildFile; fileRef = A00000000000000000000075; };
        A00000000000000000000073 = {isa = PBXBuildFile; fileRef = A00000000000000000000077; settings = {ATTRIBUTES = (RemoveHeadersOnCopy); }; };
        A00000000000000000000074 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OpenMealCameraIntent.swift; sourceTree = "<group>"; };
        A00000000000000000000075 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BiteLensControls.swift; sourceTree = "<group>"; };
        A00000000000000000000076 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = App/Config/Controls-Info.plist; sourceTree = SOURCE_ROOT; };
        A00000000000000000000077 = {isa = PBXFileReference; explicitFileType = wrapper.app-extension; includeInIndex = 0; path = BiteLensControls.appex; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000078 = {isa = PBXGroup; children = (A00000000000000000000075, A00000000000000000000096); path = App/BiteLensControls; sourceTree = "<group>"; };
        A00000000000000000000079 = {
            isa = PBXNativeTarget;
            buildConfigurationList = A00000000000000000000080;
            buildPhases = (A0000000000000000000007A, A0000000000000000000007B, A0000000000000000000007C);
            buildRules = ();
            dependencies = ();
            name = BiteLensControls;
            packageProductDependencies = ();
            productName = BiteLensControls;
            productReference = A00000000000000000000077;
            productType = "com.apple.product-type.app-extension";
        };
        A0000000000000000000007A = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000071, A00000000000000000000072); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000007B = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000007C = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000097); runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000007D = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = (A00000000000000000000073, B00000000000000000000008); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0; };
        A0000000000000000000007E = {isa = PBXContainerItemProxy; containerPortal = A00000000000000000000040; proxyType = 1; remoteGlobalIDString = A00000000000000000000079; remoteInfo = BiteLensControls; };
        A0000000000000000000007F = {isa = PBXTargetDependency; target = A00000000000000000000079; targetProxy = A0000000000000000000007E; };
        A00000000000000000000080 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000081, A00000000000000000000082); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000081 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                APPLICATION_EXTENSION_API_ONLY = YES;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Controls-Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens.Controls";
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SKIP_INSTALL = YES;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) BITELENS_CONTROL_EXTENSION";
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Debug;
        };
        A00000000000000000000082 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                APPLICATION_EXTENSION_API_ONLY = YES;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Controls-Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens.Controls";
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SKIP_INSTALL = YES;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) BITELENS_CONTROL_EXTENSION";
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Release;
        };
        B00000000000000000000001 = {isa = PBXGroup; children = (B00000000000000000000004, B00000000000000000000017); path = App/BiteLensShare; sourceTree = "<group>"; };
        B00000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = App/Config/Share-Info.plist; sourceTree = SOURCE_ROOT; };
        B00000000000000000000003 = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = App/Config/SharedImages.entitlements; sourceTree = SOURCE_ROOT; };
        B00000000000000000000004 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareViewController.swift; sourceTree = "<group>"; };
        B00000000000000000000005 = {isa = PBXFileReference; explicitFileType = wrapper.app-extension; includeInIndex = 0; path = BiteLensShare.appex; sourceTree = BUILT_PRODUCTS_DIR; };
        B00000000000000000000006 = {isa = PBXBuildFile; fileRef = B00000000000000000000004; };
        B00000000000000000000007 = {isa = PBXBuildFile; productRef = B00000000000000000000013; };
        B00000000000000000000008 = {isa = PBXBuildFile; fileRef = B00000000000000000000005; settings = {ATTRIBUTES = (RemoveHeadersOnCopy); }; };
        B00000000000000000000009 = {isa = PBXContainerItemProxy; containerPortal = A00000000000000000000040; proxyType = 1; remoteGlobalIDString = B00000000000000000000010; remoteInfo = BiteLensShare; };
        B0000000000000000000000A = {isa = PBXTargetDependency; target = B00000000000000000000010; targetProxy = B00000000000000000000009; };
        B00000000000000000000010 = {
            isa = PBXNativeTarget;
            buildConfigurationList = B00000000000000000000014;
            buildPhases = (B00000000000000000000011, B00000000000000000000012, B00000000000000000000019);
            buildRules = ();
            dependencies = ();
            name = BiteLensShare;
            packageProductDependencies = (B00000000000000000000013);
            productName = BiteLensShare;
            productReference = B00000000000000000000005;
            productType = "com.apple.product-type.app-extension";
        };
        B00000000000000000000011 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000006); runOnlyForDeploymentPostprocessing = 0; };
        B00000000000000000000012 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000007); runOnlyForDeploymentPostprocessing = 0; };
        B00000000000000000000017 = {isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
        B00000000000000000000018 = {isa = PBXBuildFile; fileRef = B00000000000000000000017; };
        B00000000000000000000019 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000018); runOnlyForDeploymentPostprocessing = 0; };
        B00000000000000000000013 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000060; productName = BiteLensCore; };
        B00000000000000000000014 = {isa = XCConfigurationList; buildConfigurations = (B00000000000000000000015, B00000000000000000000016); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        B00000000000000000000015 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                APPLICATION_EXTENSION_API_ONLY = YES;
                CODE_SIGN_ENTITLEMENTS = App/Config/SharedImages.entitlements;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Share-Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens.Share";
                PRODUCT_NAME = "$(TARGET_NAME)";
                REGISTER_APP_GROUPS = YES;
                SDKROOT = iphoneos;
                SKIP_INSTALL = YES;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Debug;
        };
        B00000000000000000000016 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                APPLICATION_EXTENSION_API_ONLY = YES;
                CODE_SIGN_ENTITLEMENTS = App/Config/SharedImages.entitlements;
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = NO;
                INFOPLIST_FILE = App/Config/Share-Info.plist;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens.Share";
                PRODUCT_NAME = "$(TARGET_NAME)";
                REGISTER_APP_GROUPS = YES;
                SDKROOT = iphoneos;
                SKIP_INSTALL = YES;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
            };
            name = Release;
        };
        C00000000000000000000011 = {isa = PBXBuildFile; fileRef = C00000000000000000000012; };
        C00000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CaptureSmokeTests.swift; sourceTree = "<group>"; };
        C00000000000000000000013 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BiteLensUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
        C00000000000000000000020 = {isa = PBXGroup; children = (C00000000000000000000012); path = App/BiteLensUITests; sourceTree = "<group>"; };
        C00000000000000000000030 = {
            isa = PBXNativeTarget;
            buildConfigurationList = C00000000000000000000050;
            buildPhases = (C00000000000000000000031, C00000000000000000000032, C00000000000000000000035);
            buildRules = ();
            dependencies = (C00000000000000000000034);
            name = BiteLensUITests;
            packageProductDependencies = ();
            productName = BiteLensUITests;
            productReference = C00000000000000000000013;
            productType = "com.apple.product-type.bundle.ui-testing";
        };
        C00000000000000000000031 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (C00000000000000000000011); runOnlyForDeploymentPostprocessing = 0; };
        C00000000000000000000032 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        C00000000000000000000033 = {isa = PBXContainerItemProxy; containerPortal = A00000000000000000000040; proxyType = 1; remoteGlobalIDString = A00000000000000000000030; remoteInfo = BiteLens; };
        C00000000000000000000034 = {isa = PBXTargetDependency; target = A00000000000000000000030; targetProxy = C00000000000000000000033; };
        C00000000000000000000035 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        C00000000000000000000050 = {isa = XCConfigurationList; buildConfigurations = (C00000000000000000000051, C00000000000000000000052); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        C00000000000000000000051 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = YES;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLensUITests";
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_EMIT_LOC_STRINGS = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
                TEST_TARGET_NAME = BiteLens;
            };
            name = Debug;
        };
        C00000000000000000000052 = {
            isa = XCBuildConfiguration;
            baseConfigurationReference = A00000000000000000000015;
            buildSettings = {
                CODE_SIGN_STYLE = Automatic;
                CURRENT_PROJECT_VERSION = 1;
                GENERATE_INFOPLIST_FILE = YES;
                IPHONEOS_DEPLOYMENT_TARGET = 18.0;
                LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");
                MARKETING_VERSION = 0.5.0;
                PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLensUITests";
                PRODUCT_NAME = "$(TARGET_NAME)";
                SDKROOT = iphoneos;
                SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
                SUPPORTS_MACCATALYST = NO;
                SWIFT_EMIT_LOC_STRINGS = NO;
                SWIFT_VERSION = 6.0;
                TARGETED_DEVICE_FAMILY = 1;
                TEST_TARGET_NAME = BiteLens;
            };
            name = Release;
        };
    };
    rootObject = A00000000000000000000040;
}
'''

# Keep the same targets for both schemes so the app and extensions share their
# source lists. Every project and target configuration has a beta counterpart.
configuration = re.compile(
    r"^        (?P<inline>[ABC][0-9A-F]{23}) = \{isa = XCBuildConfiguration; [^\n]*name = (?P<inline_name>Debug|Release); \};$"
    r"|^        (?P<block>[ABC][0-9A-F]{23}) = \{\n            isa = XCBuildConfiguration;"
    r".*?name = (?P<block_name>Debug|Release);\n        \};$",
    re.MULTILINE | re.DOTALL,
)
beta_ids = {}


def configure_bundle(contents, beta):
    for target, display_prefix in (("Info", ""), ("Share-Info", "Save to "), ("Controls-Info", "")):
        marker = f"INFOPLIST_FILE = App/Config/{target}.plist;"
        if marker not in contents:
            continue
        name = display_prefix + ("BiteLens Beta" if beta else "BiteLens")
        group = "group.$(BITELENS_IDENTIFIER_PREFIX).BiteLens" + (".Beta" if beta else "")
        scheme = "$(BITELENS_IDENTIFIER_PREFIX).bitelens" + (".beta" if beta else "")
        variant = "BETA" if beta else "PERSONAL"
        plist = "INFOPLIST_FILE = App/Config/Beta-Info.plist;" if beta and target == "Info" else marker
        if target == "Info":
            plist += (
                f'\n                BITELENS_SUPABASE_HOST = "$(BITELENS_{variant}_SUPABASE_HOST)";'
                f'\n                BITELENS_SUPABASE_PUBLISHABLE_KEY = "$(BITELENS_{variant}_SUPABASE_PUBLISHABLE_KEY)";'
            )
        return contents.replace(marker, plist +
            f'\n                BITELENS_DISPLAY_NAME = "{name}";'
            f"\n                BITELENS_APP_GROUP = \"{group}\";"
            f"\n                BITELENS_URL_SCHEME = \"{scheme}\";")
    return contents


def add_beta_configuration(match):
    identifier = match["inline"] or match["block"]
    name = match["inline_name"] or match["block_name"]
    beta_identifier = "D" + identifier[1] + identifier[0] + identifier[3:]
    beta_ids[identifier] = beta_identifier
    original = match[0]
    beta = original.replace(identifier, beta_identifier, 1).replace(
        f"name = {name};", f'name = "Beta {name}";')
    beta = beta.replace('PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens',
                        'PRODUCT_BUNDLE_IDENTIFIER = "$(BITELENS_IDENTIFIER_PREFIX).BiteLens.Beta')
    beta = beta.replace("CODE_SIGN_ENTITLEMENTS = App/Config/BiteLens.entitlements;",
                        "CODE_SIGN_ENTITLEMENTS = App/Config/SharedImages.entitlements;")
    if any(f"INFOPLIST_FILE = App/Config/{target}.plist;" in beta for target in ("Info", "Share-Info")):
        beta = beta.replace(
            "SWIFT_VERSION = 6.0;",
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) BITELENS_BETA";\n'
            "                SWIFT_VERSION = 6.0;",
        )
    return configure_bundle(original, beta=False) + "\n" + configure_bundle(beta, beta=True)


def add_beta_configuration_ids(match):
    identifiers = match[1].split(", ")
    counterparts = [beta_ids[identifier] for identifier in identifiers]
    return "buildConfigurations = (" + ", ".join(identifiers + counterparts) + ")"


project_contents = configuration.sub(add_beta_configuration, project_contents)
project_contents = re.sub(r"buildConfigurations = \(([^)]+)\)", add_beta_configuration_ids, project_contents)
(project / "project.pbxproj").write_text(project_contents)

# The personal app can open image documents. Beta imports via Photos or the share extension.
app_config = root / "App" / "Config"
with (app_config / "Info.plist").open("rb") as source:
    beta_info = plistlib.load(source)
del beta_info["CFBundleDocumentTypes"]
del beta_info["LSSupportsOpeningDocumentsInPlace"]
with (app_config / "Beta-Info.plist").open("wb") as target:
    plistlib.dump(beta_info, target, sort_keys=False)

schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
scheme_contents = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000030" BuildableName="BiteLens.app" BlueprintName="BiteLens" ReferencedContainer="container:BiteLens.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="C00000000000000000000030" BuildableName="BiteLensUITests.xctest" BlueprintName="BiteLensUITests" ReferencedContainer="container:BiteLens.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="C00000000000000000000030" BuildableName="BiteLensUITests.xctest" BlueprintName="BiteLensUITests" ReferencedContainer="container:BiteLens.xcodeproj"/>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000030" BuildableName="BiteLens.app" BlueprintName="BiteLens" ReferencedContainer="container:BiteLens.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000030" BuildableName="BiteLens.app" BlueprintName="BiteLens" ReferencedContainer="container:BiteLens.xcodeproj"/></BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(schemes / "BiteLens.xcscheme").write_text(scheme_contents)
(schemes / "BiteLens Beta.xcscheme").write_text(scheme_contents
    .replace('buildConfiguration="Debug"', 'buildConfiguration="Beta Debug"')
    .replace('buildConfiguration="Release"', 'buildConfiguration="Beta Release"'))
print("Generated BiteLens.xcodeproj")
