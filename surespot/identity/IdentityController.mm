//
//  IdentityController.m
//  surespot
//
//  Created by Adam on 6/8/13.
//  Copyright (c) 2013 surespot. All rights reserved.
//


#import "IdentityController.h"
#import "EncryptionController.h"
#import "NetworkManager.h"
#import "FileController.h"
#import "SurespotIdentity.h"
#import "NSData+Gunzip.h"
#import "PublicKeys.h"
#include <zlib.h>
#import "CredentialCachingController.h"
#import "ChatManager.h"
#import "CocoaLumberjack.h"
#import "NSData+Base64.h"
#import "NSData+SRB64Additions.h"
#import "KeychainItemWrapper.h"
#import <Security/Security.h>
#import "UIUtils.h"
#import "NSString+Sensitivize.h"
#import "NSBundle+FallbackLanguage.h"


#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
#else
static const DDLogLevel ddLogLevel = DDLogLevelOff;
#endif

@interface IdentityController()
@property (nonatomic, strong) NSMutableDictionary * keychainWrappers;
@property (nonatomic, strong) NSMutableDictionary * expectedVersions;
@end

@implementation IdentityController
+(IdentityController*)sharedInstance
{
    static IdentityController *sharedInstance = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        sharedInstance = [[self alloc] init];
        sharedInstance.keychainWrappers = [NSMutableDictionary new];
        sharedInstance.expectedVersions = [NSMutableDictionary new];
    });
    
    return sharedInstance;
}

NSString *const CACHE_IDENTITY_ID = @"_cache_identity";
NSString *const EXPORT_IDENTITY_ID = @"_export_identity";



- (SurespotIdentity *) getIdentityWithUsername:(NSString *) username andPassword:(NSString *) password {
    SurespotIdentity * identity = [[CredentialCachingController sharedInstance] getIdentityForUsername:username password:password];
    return identity;
}



-(SurespotIdentity *) loadIdentityUsername: (NSString * ) username password: (NSString *) password {
    NSString *filePath = [FileController getIdentityFile:username];
    NSData *myData = [NSData dataWithContentsOfFile:filePath];
    BOOL save = NO;
    if (!myData) {
        //busted filename, recover and resave
        NSDictionary * rawMap = [self getRawIdentityFilemap];
        filePath = [rawMap objectForKey:username];
        myData = [NSData dataWithContentsOfFile:filePath];
        
        save = YES;
    }
    
    if (myData) {
        //gunzip the identity data
        //NSError* error = nil;
        NSData* unzipped = [myData gzipInflate];
        NSData * identity = [EncryptionController decryptIdentity: unzipped withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]];
        if (identity) {
            SurespotIdentity * si = [self decodeIdentityData:identity password:password validate: NO];
            
            //recovered from busted filename, save it again and remove old one
            if (save) {
                if ([self saveIdentity:si withPassword: [password stringByAppendingString:CACHE_IDENTITY_ID]]) {
                    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
                }
            }
            
            return si;
        }
    }
    
    return nil;
}

-(NSData *) encryptIdentity: (SurespotIdentity *) identity withPassword:(NSString *)password {
    NSMutableDictionary * dic = [NSMutableDictionary dictionaryWithObjectsAndKeys: [identity username] ,@"username", [identity salt], @"salt" ,nil];
    
    
    
    NSDictionary * identityKeys = [identity keyPairs];
    NSMutableArray * encodedKeys = [[NSMutableArray alloc] init];
    for (NSInteger i=1;i<=[identity.latestVersion integerValue];i++) {
        NSString * version =[@(i) stringValue];
        
        //if we have a concrete key encode and save that
        IdentityKeys *versionedKeys = [identityKeys objectForKey:version];
        if ([versionedKeys dhPrivKey] && [versionedKeys dhPubKey] && [versionedKeys dsaPrivKey] && [versionedKeys dsaPubKey]) {
            DDLogInfo(@"saving concrete key for version %@", version);
            NSDictionary *jsonKeys = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [versionedKeys version] ,@"version",
                                      [EncryptionController encodeDHPrivateKey: [versionedKeys dhPrivKey]], @"dhPriv" ,
                                      [EncryptionController encodeDHPublicKey: [versionedKeys dhPubKey]], @"dhPub" ,
                                      [EncryptionController encodeDSAPrivateKey: [versionedKeys dsaPrivKey]], @"dsaPriv" ,
                                      [EncryptionController encodeDSAPublicKey: [versionedKeys dsaPubKey]], @"dsaPub" ,
                                      nil];
            
            [encodedKeys addObject:jsonKeys];
        }
        //otherwise use json
        else {
            DDLogInfo(@"saving json key for version %@", version);
            [encodedKeys addObject:[[identity jsonKeyPairs] objectForKey:version]];
        }
    }
    
    [dic setObject:encodedKeys forKey:@"keys"];
    NSError * error;
    NSData * jsonIdentity = [NSJSONSerialization dataWithJSONObject:dic options:kNilOptions error:&error];
    return [EncryptionController encryptIdentity:jsonIdentity withPassword:password];
    
}

-( SurespotIdentity *) decodeIdentityData: (NSData *) identityData password: (NSString *) password validate: (BOOL) validate {
    
    NSError* error;
    
    NSDictionary* dic = [NSJSONSerialization JSONObjectWithData:identityData options:NSJSONReadingMutableContainers error:&error];
    return [[SurespotIdentity alloc] initWithDictionary: dic validate: validate];
}

-(void) setLoggedInUserIdentity: (SurespotIdentity *) identity password: (NSString *) password cookie: (NSHTTPCookie *) cookie relogin: (BOOL) relogin {
    @synchronized (self) {
        [[CredentialCachingController sharedInstance] loginIdentity:identity password: password cookie: cookie isActive: !relogin];
        //set last logged in user pref
        [[NSUserDefaults standardUserDefaults] setObject:identity.username forKey:@"last_user"];
        
        //        if (!relogin) {
        //            [[[ChatManager sharedInstance] getChatController: identity.username] login];
        //        }
    }
}



- (void) createIdentityWithUsername: (NSString *) username
                        andPassword: (NSString *) password
                            andSalt: (NSString *) salt
                            andKeys: (IdentityKeys *) keys
                             cookie: (NSHTTPCookie *) cookie {
    
    
    SurespotIdentity * identity = [[SurespotIdentity alloc] initWithUsername:username andSalt:salt keys:keys];
    
    [self saveIdentity:identity withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]];
    [self setLoggedInUserIdentity:identity password: password cookie:cookie relogin:NO];
}

- (NSString *) saveIdentity: (SurespotIdentity *) identity withPassword: (NSString *) password {
    NSString * filePath = [FileController getIdentityFile:identity.username];
    NSData * encryptedCompressedIdentityData = [[self encryptIdentity:identity withPassword:password] gzipDeflate];
    BOOL written = [encryptedCompressedIdentityData writeToFile:filePath atomically:TRUE];
    return written ? filePath : nil;
}

- (NSString *) saveIdentityDocuments: (SurespotIdentity *) identity withPassword: (NSString *) password {
    NSString * filePath = [FileController getIdentityFileDocuments:identity.username];
    NSData * encryptedCompressedIdentityData = [[self encryptIdentity:identity withPassword:[password stringByAppendingString:EXPORT_IDENTITY_ID]] gzipDeflate];
    BOOL written = [encryptedCompressedIdentityData writeToFile:filePath atomically:TRUE];
    return written ? filePath : nil;
}

- (NSArray *) getIdentityNames {
    NSString * identityDir = [FileController getIdentityDir];
    NSArray * dirfiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:identityDir error:NULL];
    NSMutableArray * identityNames = [[NSMutableArray alloc] init];
    NSString * file;
    for (file in dirfiles) {
        [identityNames addObject:[self identityNameFromFile:file]];
    }
    
    return [identityNames sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [obj1 compare:obj2 options:NSCaseInsensitiveSearch];
    }];
    
}

- (NSDictionary *) getRawIdentityFilemap {
    NSString * identityDir = [FileController getIdentityDir];
    NSArray * dirfiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:identityDir error:NULL];
    NSMutableDictionary * identityNames = [[NSMutableDictionary alloc] init];
    NSString * file;
    for (file in dirfiles) {
        if ([[file pathExtension] isEqualToString:IDENTITY_EXTENSION]) {
            NSString * identity = [self identityNameFromFile:file];
            [identityNames setObject:[[FileController getIdentityDir ] stringByAppendingPathComponent:file] forKey:identity];
        }
    }
    
    return identityNames;
}


- (NSString * ) identityNameFromFile: (NSString *) file {
    if ([[file pathExtension] isEqualToString:IDENTITY_EXTENSION]) {
        return[[file stringByDeletingPathExtension] caseSensitivize];
    }
    
    return nil;
}

- (void) userLoggedInWithIdentity: (SurespotIdentity *) identity password: (NSString *) password cookie:(NSHTTPCookie *) cookie relogin: (BOOL) relogin {
    [self setLoggedInUserIdentity:identity password: password cookie: cookie relogin:relogin];
}


- (NSString *) getLoggedInUser {
    return [[CredentialCachingController sharedInstance] activeUsername];
}

-(NSString *) getLastLoggedInUser {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"last_user"];
}

-(void) logout {
    @synchronized (self) {
        [self clearStoredPasswordForIdentity: [self getLoggedInUser]];
        [[CredentialCachingController sharedInstance] logout];
    }
}

- (NSString *) getOurLatestVersion: (NSString *) ourUsername {
    return [[[CredentialCachingController sharedInstance] getIdentityForUsername:ourUsername] latestVersion];
}

- (void) getTheirLatestVersionForOurUsername: (NSString *) ourUsername theirUsername: (NSString *) theirUsername callback:(CallbackStringBlock) callback {
    DDLogVerbose(@"getTheirLatestVersionForUsername");
    [[CredentialCachingController sharedInstance] getLatestVersionForOurUsername: ourUsername theirUsername: theirUsername callback: callback];
}

-(BOOL) verifyPublicKeys: (NSDictionary *) keys {
    
    BOOL dhVerify = [EncryptionController
                     verifyPublicKeySignature: [NSData dataFromBase64String:[keys objectForKey:@"dhPubSig"]]
                     data:[keys objectForKey:@"dhPub"]];
    
    if (!dhVerify) {
        return NO;
    }
    
    BOOL dsaVerify = [EncryptionController
                      verifyPublicKeySignature: [NSData dataFromBase64String:[keys objectForKey:@"dsaPubSig"]]
                      data:[keys objectForKey:@"dsaPub"]];
    
    if (!dsaVerify) {
        return NO;
    }
    
    return YES;
}

-(PublicKeys *) loadPublicKeysOurUsername: (NSString *) ourUsername theirUsername: (NSString *) theirUsername version: (NSString *) version {
    NSString * filename =[FileController getPublicKeyFilenameForOurUsername:ourUsername theirUsername:theirUsername version: version];
    NSDictionary * keys = [NSKeyedUnarchiver unarchiveObjectWithFile:filename];
    if (keys) {
        ECDHPublicKey * dhPub = [EncryptionController recreateDhPublicKey:[keys objectForKey:@"dhPub"]];
        ECDHPublicKey * dsaPub = [EncryptionController recreateDsaPublicKey:[keys objectForKey:@"dsaPub"]];
        
        PublicKeys* pk = [[PublicKeys alloc] init];
        pk.dhPubKey = dhPub;
        pk.dsaPubKey = dsaPub;
        pk.version = version;
        
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filename error:nil];
        NSDate *date = [attributes fileModificationDate];
        
        pk.lastModified = date;
        DDLogInfo(@"loaded public keys for username: %@, version: %@ from filename: %@", theirUsername,version,filename);
        return pk;
    }
    
    return nil;
}

-(void) savePublicKeys: (NSDictionary * ) keys ourUsername: (NSString *) ourUsername theirUsername: (NSString *) theirUsername version: (NSString *)version{
    NSString * filename =[FileController getPublicKeyFilenameForOurUsername: ourUsername theirUsername: theirUsername version: version];
    BOOL saved =[NSKeyedArchiver archiveRootObject:keys toFile:filename];
    DDLogInfo(@"saved public keys for username: %@, version: %@ to filename: %@  with success: %@", theirUsername,version,filename, saved?@"YES":@"NO");
}

//we don't want to delete ourselves if we're in the process of generating new keys
-(void) setExpectedKeyVersionForUsername: (NSString *) username version: (NSString *) version {
    [_expectedVersions setObject:version forKey:username];
}

-(void) updateLatestVersionForUsername: (NSString *) username version: (NSString * ) version {
    // if we have the latest version locally, if we don't then this user has
    // been revoked from a different device
    // and should not be used on this device anymore
    if ([[self getIdentityNames] containsObject:username] && [version integerValue] > [[self getOurLatestVersion: username] integerValue] && ![[_expectedVersions objectForKey:username] isEqualToString:version]) {
        DDLogInfo(@"user key revoked, deleting data and logging out. username: %@", username);
        [self deleteIdentityUsername:username preserveBackedUpIdentity: NO];
    }
    else {
        [[CredentialCachingController sharedInstance] updateLatestVersionForUsername: username version: version];
    }
}

-(void) deleteIdentityUsername: (NSString *) username preserveBackedUpIdentity: (BOOL) preserveBackedUpIdentity {
    //make sure we wipe the identity file first so it doesn't show when we return to login screen
    [FileController wipeIdentityData: username preserveBackedUpIdentity: preserveBackedUpIdentity];
    [[[NetworkManager sharedInstance] getNetworkController:username] setUnauthorized];
    
    [[CredentialCachingController sharedInstance] clearIdentityData:username];
    
    //remove password from keychain
    [self clearStoredPasswordForIdentity:username];
    
    //then wipe the messages saved by logging out
    [FileController wipeIdentityData: username preserveBackedUpIdentity: preserveBackedUpIdentity];
}

-(NSString *) getStoredPasswordForIdentity: (NSString *) username {
    if ([UIUtils stringIsNilOrEmpty:username]) {
        return nil;
    }
    
    KeychainItemWrapper * wrapper = [_keychainWrappers objectForKey:username];
    if (!wrapper) {
        wrapper = [[KeychainItemWrapper alloc] initWithIdentifier:username accessGroup:nil];
        [_keychainWrappers setObject:wrapper forKey:username];
    }
    
    NSString * password = [wrapper objectForKey:(__bridge id)kSecValueData];
    if ([UIUtils stringIsNilOrEmpty:password]) {
        return nil;
    }
    
    return password;
}

-(void) storePasswordForIdentity: (NSString *) username password: (NSString *) password {
    //save password in keychain
    KeychainItemWrapper * wrapper = [_keychainWrappers objectForKey:username];
    if (!wrapper) {
        wrapper = [[KeychainItemWrapper alloc] initWithIdentifier:username accessGroup:nil];
        [_keychainWrappers setObject:wrapper forKey:username];
    }
    
    [wrapper setObject:password forKey:(__bridge id)kSecValueData];
    
}

-(void) clearStoredPasswordForIdentity: (NSString *) username {
    KeychainItemWrapper * wrapper = [_keychainWrappers objectForKey:username];
    if (!wrapper) {
        wrapper = [[KeychainItemWrapper alloc] initWithIdentifier:username accessGroup:nil];
    }
    [wrapper resetKeychainItem];
    [_keychainWrappers removeObjectForKey:username];
    
    //remove secrets, cookies, etc. from disk
    [FileController deleteDataForUsername:username];
}

-(void) importIdentityData: (NSData *) identityData username: (NSString *) username password: (NSString *) password callback: (CallbackBlock) callback {
    NSData * decryptedIdentity = [EncryptionController decryptIdentity: identityData withPassword:[password stringByAppendingString:EXPORT_IDENTITY_ID]];
    if (!decryptedIdentity) {
        callback([NSString stringWithFormat:NSLocalizedString(@"could_not_restore_identity_name", nil), username]);
        return;
    }
    
    //get the identity without validating to validate with server where we only need the latest ids
    SurespotIdentity * identity = [self decodeIdentityData:decryptedIdentity password:password validate:NO];
    if (!identity) {
        callback([NSString stringWithFormat:NSLocalizedString(@"could_not_restore_identity_name", nil), username]);
        return;
    }
    
    NSData * saltBytes = [NSData dataFromBase64String:identity.salt];
    NSData * derivedPassword = [EncryptionController deriveKeyUsingPassword:password andSalt:saltBytes];
    NSData * encodedPassword = [derivedPassword SR_dataByBase64Encoding];
    
    NSData * signature = [EncryptionController signUsername:username andPassword: encodedPassword withPrivateKey:[identity getDsaPrivateKey]];
    NSString * passwordString = [derivedPassword SR_stringByBase64Encoding];
    NSString * signatureString = [signature SR_stringByBase64Encoding];
    
    [[[NetworkManager sharedInstance] getNetworkController:identity.username]
     validateUsername:identity.username
     password:passwordString
     signature:signatureString
     successBlock:^(NSURLSessionTask *operation, id responseObject) {
         DDLogDebug(@"validated user");
         //regenerate the identity with full validation for saving
         SurespotIdentity * validatedIdentity = [self decodeIdentityData:decryptedIdentity password:password validate:YES];
         if ([self saveIdentity:validatedIdentity withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]]) {
             [[CredentialCachingController sharedInstance] updateIdentity: identity onlyIfExists: YES];
             callback(nil);
         }
         else {
             callback([NSString stringWithFormat:NSLocalizedString(@"could_not_restore_identity_name", nil), username]);
         }
         
     } failureBlock:^(NSURLSessionTask *operation, NSError *error) {
         switch ([(NSHTTPURLResponse*)operation.response statusCode]) {
             case 403:
                 callback(NSLocalizedString(@"incorrect_password_or_key", nil));
                 break;
             case 404:
                 callback(NSLocalizedString(@"no_such_user", nil));
                 break;
             default:
                 callback([NSString stringWithFormat:NSLocalizedString(@"could_not_restore_identity_name", nil), username]);
                 break;
         }
     }];
}

-(void) importIdentityFilename: (NSString *) filePath username: (NSString * ) username password: (NSString *) password callback: (CallbackBlock) callback {
    
    NSData *myData = [NSData dataWithContentsOfFile:filePath];
    if (myData) {
        //gunzip the identity data
        //NSError* error = nil;
        NSData* unzipped = [myData gzipInflate];
        
        if (unzipped) {
            [self importIdentityData:unzipped username:username password:password callback:callback];
        }
    }
}

-(void) exportIdentityToDocumentsForUsername: (NSString *) username password: (NSString *) password callback: (CallbackErrorBlock) callback {
    SurespotIdentity * identity = [self getIdentityWithUsername:username andPassword:password];
    if (!identity) {
        callback(NSLocalizedString(@"no_identity_exported", username), nil);
        return;
    }
    
    NSData * saltBytes = [NSData dataFromBase64String:identity.salt];
    NSData * derivedPassword = [EncryptionController deriveKeyUsingPassword:password andSalt:saltBytes];
    NSData * encodedPassword = [derivedPassword SR_dataByBase64Encoding];
    
    NSData * signature = [EncryptionController signUsername:username andPassword: encodedPassword withPrivateKey:[identity getDsaPrivateKey]];
    NSString * passwordString = [derivedPassword SR_stringByBase64Encoding];
    NSString * signatureString = [signature SR_stringByBase64Encoding];
    
    
    
    [[[NetworkManager sharedInstance] getNetworkController:username] validateUsername:username password:passwordString signature:signatureString successBlock:^(NSURLSessionTask *operation, id responseObject) {
        
        
        if ([self saveIdentityDocuments:identity withPassword:password]) {
            callback(nil,nil);
        }
        else {
            callback(nil, @"no_identity_exported");
        }
    } failureBlock:^(NSURLSessionTask *operation, NSError *error) {
        switch ([(NSHTTPURLResponse*)operation.response statusCode]) {
            case 403:
            case 404:
                callback(NSLocalizedString(@"incorrect_password_or_key", nil), nil);
                break;
            default:
                callback([NSString stringWithFormat:NSLocalizedString(@"no_identity_exported", nil), username], nil);
                break;
        }
    }];
}

-(void) exportIdentityDataForUsername: (NSString *) username password: (NSString *) password callback: (CallbackErrorBlock) callback {
    SurespotIdentity * identity = [self getIdentityWithUsername:username andPassword:password];
    if (!identity) {
        callback(NSLocalizedString(@"could_not_backup_identity_to_google_drive", username), nil);
        return;
    }
    
    NSData * saltBytes = [NSData dataFromBase64String:identity.salt];
    NSData * derivedPassword = [EncryptionController deriveKeyUsingPassword:password andSalt:saltBytes];
    NSData * encodedPassword = [derivedPassword SR_dataByBase64Encoding];
    
    NSData * signature = [EncryptionController signUsername:username andPassword: encodedPassword withPrivateKey:[identity getDsaPrivateKey]];
    NSString * passwordString = [derivedPassword SR_stringByBase64Encoding];
    NSString * signatureString = [signature SR_stringByBase64Encoding];
    
    
    
    [[[NetworkManager sharedInstance] getNetworkController:username] validateUsername:username password:passwordString signature:signatureString successBlock:^(NSURLSessionTask *operation, id responseObject) {
        callback(nil, [self encryptIdentity:identity withPassword:[password stringByAppendingString:EXPORT_IDENTITY_ID]]);
        
    } failureBlock:^(NSURLSessionTask *operation, NSError *error) {
        switch ([(NSHTTPURLResponse*)operation.response statusCode]) {
            case 403:
            case 404:
                callback(NSLocalizedString(@"incorrect_password_or_key", nil), nil);
                break;
            default:
                callback([NSString stringWithFormat:NSLocalizedString(@"could_not_backup_identity_to_google_drive", nil), username], nil);
                break;
        }
    }];
}

-(void) removeExpectedKeyVersionForUsername: (NSString *) username {
    [_expectedVersions removeObjectForKey:username];
}

-(void) rollKeysForUsername: (NSString *) username
                   password: (NSString *) password
                 keyVersion: (NSString *)  keyVersion
                       keys: (IdentityKeys *) keys {
    
    SurespotIdentity * identity = [self getIdentityWithUsername:username andPassword:password];
    [identity addKeysWithVersion:keyVersion keys:keys];
    [self saveIdentity:identity withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]];
    [[CredentialCachingController sharedInstance] updateIdentity: identity onlyIfExists: YES];
    
    [self removeExpectedKeyVersionForUsername:username];
}

-(void) updatePasswordForUsername: (NSString *) username currentPassword: (NSString *) currentPassword newPassword: (NSString *) newPassword newSalt: (NSString *) newSalt {
    SurespotIdentity * identity = [self getIdentityWithUsername:username andPassword:currentPassword];
    identity.salt = newSalt;
    [self saveIdentity:identity withPassword:[newPassword stringByAppendingString:CACHE_IDENTITY_ID]];
    [[CredentialCachingController sharedInstance] updateIdentity: identity onlyIfExists: YES];
    if ([self getStoredPasswordForIdentity:username]) {
        [self storePasswordForIdentity:username password:newPassword];
    }
}

-(NSInteger) getIdentityCount {
    return [self getIdentityNames].count;
}

-(NSDictionary *) updateSignatures: (NSString *) username {
    SurespotIdentity * identity = [[CredentialCachingController sharedInstance] getIdentityForUsername:username];
    ECDSAPrivateKey * privateDsaKey = [identity getDsaPrivateKeyForVersion:@"1"];
    NSMutableDictionary * signatures = [[NSMutableDictionary alloc] init];
    
    NSInteger latestVersion = [[identity latestVersion] integerValue];
    for (int i = 1;i<=latestVersion;i++) {
        NSString * currentVersion = [@(i) stringValue];
        ECDHPrivateKey * dhPriv = [identity getDhPrivateKeyForVersion:currentVersion];
        ECDSAPrivateKey * dsaPriv = [identity getDsaPrivateKeyForVersion:currentVersion];
        
        
        NSString * sDhPub = [[EncryptionController encodeDHPublicKeyData:[EncryptionController createPublicDHFromPrivKey:dhPriv]] SR_stringByBase64Encoding];
        NSString * sDsaPub = [[EncryptionController encodeDSAPublicKeyData:[EncryptionController createPublicDSAFromPrivKey:dsaPriv]] SR_stringByBase64Encoding];
        
        DDLogInfo(@"signed dh: %@, dsa: %@", sDhPub, sDsaPub);
        
        
        [signatures setObject:[[EncryptionController signUsername:[identity username] andVersion:i andDhPubKey:sDhPub andDsaPubKey:sDsaPub withPrivateKey:privateDsaKey] SR_stringByBase64Encoding] forKey:currentVersion];
        if (i>1) {
            privateDsaKey = [identity getDsaPrivateKeyForVersion:[@(i) stringValue]];
        }
    }
    
    return signatures;
}

@end
