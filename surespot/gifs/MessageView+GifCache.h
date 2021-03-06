//
//  MessageView+GifCache.h
//  surespot
//
//  Created by Adam on 5/11/17.
//  Copyright © 2017 surespot. All rights reserved.
//

#import "MessageView.h"
#import "SurespotMessage.h"
#import "SurespotConstants.h"

@interface MessageView (GifCache)

- (void)setMessage:(SurespotMessage *) message
       ourUsername:(NSString *) ourUsername
          callback:(CallbackBlock)callback
      retryAttempt:(NSInteger) retryAttempt;

- (void)cancelCurrentImageLoad;
@end
