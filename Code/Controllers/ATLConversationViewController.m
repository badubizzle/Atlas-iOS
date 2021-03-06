//
//  ATLUIConversationViewController.m
//  Atlas
//
//  Created by Kevin Coleman on 8/31/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <AssetsLibrary/AssetsLibrary.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <MediaPlayer/MediaPlayer.h>
#import "ATLConversationViewController.h"
#import "ATLConversationCollectionView.h"
#import "ATLConstants.h"
#import "ATLDataSourceChange.h"
#import "ATLMessagingUtilities.h"
#import "ATLConversationView.h"
#import "ATLConversationDataSource.h"
#import "ATLMediaAttachment.h"
#import "ATLLocationManager.h"
#import "LYRIdentity+ATLParticipant.h"

@import AVFoundation;

@interface ATLConversationViewController () <UICollectionViewDataSource, UICollectionViewDelegate, CLLocationManagerDelegate>

@property (nonatomic) ATLConversationDataSource *conversationDataSource;
@property (nonatomic, readwrite) LYRQueryController *queryController;
@property (nonatomic) BOOL shouldDisplayAvatarItem;
@property (nonatomic) NSMutableOrderedSet *typingParticipantIDs;
@property (nonatomic) NSMutableArray *objectChanges;
@property (nonatomic) NSHashTable *sectionHeaders;
@property (nonatomic) NSHashTable *sectionFooters;

@property (nonatomic) BOOL showingMoreMessagesIndicator;
@property (nonatomic) BOOL hasAppeared;

@property (nonatomic) ATLLocationManager *locationManager;
@property (nonatomic) BOOL shouldShareLocation;
@property (nonatomic) BOOL canDisableAddressBar;
@property (nonatomic) dispatch_queue_t animationQueue;
@property (nonatomic) BOOL expandingPaginationWindow;

@end

@implementation ATLConversationViewController

static NSInteger const ATLMoreMessagesSection = 0;
static NSString *const ATLPushNotificationSoundName = @"layerbell.caf";
static NSString *const ATLDefaultPushAlertGIF = @"sent you a GIF.";
static NSString *const ATLDefaultPushAlertImage = @"sent you a photo.";
static NSString *const ATLDefaultPushAlertLocation = @"sent you a location.";
static NSString *const ATLDefaultPushAlertVideo = @"sent you a video.";
static NSString *const ATLDefaultPushAlertText = @"sent you a message.";
static NSInteger const ATLPhotoActionSheet = 1000;

+ (NSCache *)sharedMediaAttachmentCache
{
    static NSCache *_sharedCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedCache = [NSCache new];
    });
    return _sharedCache;
}

+ (instancetype)conversationViewControllerWithLayerClient:(LYRClient *)layerClient;
{
    NSAssert(layerClient, @"Layer Client cannot be nil");
    return [[self alloc] initWithLayerClient:layerClient];
}

- (instancetype)initWithLayerClient:(LYRClient *)layerClient
{
    self = [super init];
    if (self) {
        _layerClient = layerClient;
        [self lyr_commonInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];
    if (self) {
        [self lyr_commonInit];
    }
    return self;
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to call designated initializer." userInfo:nil];
    return nil;
}

- (void)lyr_commonInit
{
    _dateDisplayTimeInterval = 60*60;
    _marksMessagesAsRead = YES;
    _shouldDisplayAvatarItemForOneOtherParticipant = NO;
    _shouldDisplayAvatarItemForAuthenticatedUser = NO;
    _avatarItemDisplayFrequency = ATLAvatarItemDisplayFrequencySection;
    _typingParticipantIDs = [NSMutableOrderedSet new];
    _sectionHeaders = [NSHashTable weakObjectsHashTable];
    _sectionFooters = [NSHashTable weakObjectsHashTable];
    _objectChanges = [NSMutableArray new];
    _animationQueue = dispatch_queue_create("com.atlas.animationQueue", DISPATCH_QUEUE_SERIAL);
}

- (void)loadView
{
    [super loadView];
    // Collection View Setup
    self.collectionView = [[ATLConversationCollectionView alloc] initWithFrame:CGRectZero
                                                          collectionViewLayout:[[UICollectionViewFlowLayout alloc] init]];
    self.collectionView.delegate = self;
    self.collectionView.dataSource = self;
}

- (void)setLayerClient:(LYRClient *)layerClient
{
    if (self.hasAppeared) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Layer Client cannot be set after the view has been presented" userInfo:nil];
    }
    _layerClient = layerClient;
}

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    if (!self.conversationDataSource) {
        [self fetchLayerMessages];
    }
    
    [self configureControllerForConversation];
    self.messageInputToolbar.inputToolBarDelegate = self;
    self.addressBarController.delegate = self;
    self.canDisableAddressBar = YES;
    [self atl_registerForNotifications];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.addressBarController && self.conversation.lastMessage && self.canDisableAddressBar) {
        [self.addressBarController disable];
        [self configureAddressBarForConversation];
    }
    
    
    
    self.canDisableAddressBar = YES;
    if (!self.hasAppeared) {
        [self.collectionView layoutIfNeeded];
    }
    if (!self.hasAppeared && [[[self class] sharedMediaAttachmentCache] objectForKey:self.conversation.identifier]) {
        [self loadCachedMediaAttachments];
    }
    
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.collectionView reloadData];
    
    //NSLog(@"Total messages to display: %@",@(self.lastReadMessageIndex));
    //NSLog(@"Total unread: %@", @(self.lastReadMessageIndex));
    
    if(!self.hasAppeared){
        //[self scrollToFirstUnreadOrBottom:NO];
    }
    self.hasAppeared = YES;
    
    if (self.addressBarController && !self.addressBarController.isDisabled) {
        [self.addressBarController.addressBarView.addressBarTextView becomeFirstResponder];
    }
    
}

-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    if(!self.hasAppeared){
        [self scrollToFirstUnreadOrBottom:NO];
    }
}

-(void)scrollToFirstUnreadOrBottom:(BOOL)animated{
    if(self.lastReadMessageIndex==0){
        //section 0 is for load more
        self.lastReadMessageIndex=1;
    }
    if(self.conversationDataSource.totalMessagesToDisplay>0){
        /*
         if we have 40 messages to display with 5 unread,
         lastreadmessageindex will be 35
         
         scroll to first unread message
         index of first unread message will be
         lastreadmessage+1
         */
        
        if(self.lastReadMessageIndex!=1 && self.lastReadMessageIndex+1<=self.conversationDataSource.totalMessagesToDisplay){
            [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:0  inSection:self.lastReadMessageIndex+1] atScrollPosition:UICollectionViewScrollPositionNone animated:animated];
        }else{
            
            [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:0  inSection:self.lastReadMessageIndex] atScrollPosition:UICollectionViewScrollPositionNone animated:animated];
        }
    }
}

- (void)dealloc
{
    if (self.messageInputToolbar.mediaAttachments.count > 0) {
        [self cacheMediaAttachments];
    }
    self.collectionView.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)cacheMediaAttachments
{
    [[[self class] sharedMediaAttachmentCache] setObject:self.messageInputToolbar.mediaAttachments forKey:self.conversation.identifier];
}

- (void)loadCachedMediaAttachments
{
    NSArray *mediaAttachments = [[[self class] sharedMediaAttachmentCache] objectForKey:self.conversation.identifier];
    for (int i = 0; i < mediaAttachments.count; i++) {
        ATLMediaAttachment *attachment = [mediaAttachments objectAtIndex:i];
        BOOL shouldHaveLineBreak = (i < mediaAttachments.count - 1) || !(attachment.mediaMIMEType == ATLMIMETypeTextPlain);
        [self.messageInputToolbar insertMediaAttachment:attachment withEndLineBreak:shouldHaveLineBreak];
    }
    [[[self class] sharedMediaAttachmentCache] removeObjectForKey:self.conversation.identifier];
}

#pragma mark - Conversation Data Source Setup

- (void)setConversation:(LYRConversation *)conversation
{
    if (!conversation && !_conversation) return;
    if ([conversation isEqual:_conversation]) return;
    
    _conversation = conversation;
    
    self.showingMoreMessagesIndicator = NO;
    [self.typingParticipantIDs removeAllObjects];
    [self updateTypingIndicatorOverlay:NO];
    
    // Set up the controller for the conversation
    [self configureControllerForConversation];
    [self configureAddressBarForChangedParticipants];
    
    if (conversation) {
        [self fetchLayerMessages];
    } else {
        self.conversationDataSource = nil;
        [self.collectionView reloadData];
    }
    CGSize contentSize = self.collectionView.collectionViewLayout.collectionViewContentSize;
    [self.collectionView setContentOffset:[self bottomOffsetForContentSize:contentSize] animated:NO];
}

- (void)fetchLayerMessages
{
    if (!self.conversation) return;
    
    LYRQuery *query = [LYRQuery queryWithQueryableClass:[LYRMessage class]];
    
    LYRPredicate *mimePredicate = [LYRPredicate predicateWithProperty:@"parts.MIMEType" predicateOperator:LYRPredicateOperatorIsNotEqualTo value:@"text/hope-init"];
    
    
    LYRPredicate *convoPredicate = [LYRPredicate predicateWithProperty:@"conversation" predicateOperator:LYRPredicateOperatorIsEqualTo value:self.conversation];
    
   query.predicate=[LYRCompoundPredicate compoundPredicateWithType:LYRCompoundPredicateTypeAnd subpredicates:@[mimePredicate, convoPredicate]];        
    
    query.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"position" ascending:YES]];
    
    
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:willLoadWithQuery:)]) {
        query = [self.dataSource conversationViewController:self willLoadWithQuery:query];
        if (![query isKindOfClass:[LYRQuery class]]){
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Data source must return an `LYRQuery` object." userInfo:nil];
        }
    }
    
    self.conversationDataSource = [ATLConversationDataSource dataSourceWithLayerClient:self.layerClient query:query];
    if (!self.conversationDataSource) {
        return;
    }
    self.conversationDataSource.queryController.delegate = self;
    self.queryController = self.conversationDataSource.queryController;
    self.showingMoreMessagesIndicator = NO;
    self.lastReadMessageIndex = self.conversationDataSource.lastUnreadMessageIndex;
    
    
    [self.collectionView reloadData];
    
    //NSLog(@"Rows: %@", @([self numberOfSectionsInCollectionView:self.collectionView]));
    
    
}

#pragma mark - Conntroller Setup

- (void)configureControllerForConversation
{
    // Configure avatar image display
    NSMutableSet *otherParticipantIDs = [[self.conversation.participants valueForKey:@"userID"] mutableCopy];
    if (self.layerClient.authenticatedUser) [otherParticipantIDs removeObject:self.layerClient.authenticatedUser.userID];
    self.shouldDisplayAvatarItem = (otherParticipantIDs.count > 1) ? YES : self.shouldDisplayAvatarItemForOneOtherParticipant;
    
    // Configure message bar button enablement
    BOOL shouldEnableButton = self.conversation ? YES : NO;
    self.messageInputToolbar.rightAccessoryButton.enabled = shouldEnableButton;
    self.messageInputToolbar.leftAccessoryButton.enabled = shouldEnableButton;
    
    // Mark all messages as read if needed
    if (self.conversation.lastMessage && self.marksMessagesAsRead) {
        [self.conversation markAllMessagesAsRead:nil];
    }
}

- (void)configureAddressBarForConversation
{
    if (!self.dataSource) return;
    if (!self.addressBarController) return;
    
    NSMutableOrderedSet *participantIdentifiers = [NSMutableOrderedSet orderedSetWithSet:[self.conversation.participants valueForKey:@"userID"]];
    if ([participantIdentifiers containsObject:self.layerClient.authenticatedUser.userID]) {
        [participantIdentifiers removeObject:self.layerClient.authenticatedUser.userID];
    }
    [self.addressBarController setSelectedParticipants:[self participantsForIdentifiers:participantIdentifiers]];
}

# pragma mark - UICollectionViewDataSource

/**
 Atlas - The `ATLConversationViewController` component uses one `LYRMessage` to represent each row.
 */
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) return 0;
    // Each message is represented by one cell no matter how many parts it has.
    return 1;
}

/**
 Atlas - The `ATLConversationViewController` component uses `LYRMessage` objects to represent sections.
 */
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return [self.conversationDataSource.queryController numberOfObjectsInSection:0] + ATLNumberOfSectionsBeforeFirstMessageSection;
}

/**
 Atlas - Configuring a subclass of `ATLMessageCollectionViewCell` to be displayed on screen. `Atlas` supports both `ATLIncomingMessageCollectionViewCell` and `ATLOutgoingMessageCollectionViewCell`.
 */
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    NSString *reuseIdentifier = [self reuseIdentifierForMessage:message atIndexPath:indexPath];
    
    UICollectionViewCell<ATLMessagePresenting> *cell =  [self.collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];
    [self configureCell:cell forMessage:message indexPath:indexPath];
    if ([self.delegate respondsToSelector:@selector(conversationViewController:configureCell:forMessage:)]) {
        [self.delegate conversationViewController:self configureCell:cell forMessage:message];
    }
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [self notifyDelegateOfMessageSelection:[self.conversationDataSource messageAtCollectionViewIndexPath:indexPath]];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [self heightForMessageAtIndexPath:indexPath];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == ATLMoreMessagesSection) {
        ATLConversationCollectionViewMoreMessagesHeader *header = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLMoreMessagesHeaderIdentifier forIndexPath:indexPath];
        return header;
    }
    if (kind == UICollectionElementKindSectionHeader) {
        ATLConversationCollectionViewHeader *header = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLConversationViewHeaderIdentifier forIndexPath:indexPath];
        [self configureHeader:header atIndexPath:indexPath];
        [self.sectionHeaders addObject:header];
        return header;
    } else {
        ATLConversationCollectionViewFooter *footer = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLConversationViewFooterIdentifier forIndexPath:indexPath];
        [self configureFooter:footer atIndexPath:indexPath];
        [self.sectionFooters addObject:footer];
        return footer;
    }
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) {
        return self.showingMoreMessagesIndicator ? CGSizeMake(0, 30) : CGSizeZero;
    }
    NSAttributedString *dateString;
    NSString *participantName;
    if ([self shouldDisplayDateLabelForSection:section]) {
        dateString = [self attributedStringForMessageDate:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    if ([self shouldDisplaySenderLabelForSection:section]) {
        participantName = [self participantNameForMessage:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    CGFloat height = [ATLConversationCollectionViewHeader headerHeightWithDateString:dateString participantName:participantName inView:self.collectionView];
    return CGSizeMake(0, height);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) return CGSizeZero;
    NSAttributedString *readReceipt;
    if ([self shouldDisplayReadReceiptForSection:section]) {
        readReceipt = [self attributedStringForRecipientStatusOfMessage:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    BOOL shouldClusterMessage = [self shouldClusterMessageAtSection:section];
    CGFloat height = [ATLConversationCollectionViewFooter footerHeightWithRecipientStatus:readReceipt clustered:shouldClusterMessage];
    return CGSizeMake(0, height);
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    // When the keyboard is being dragged, we need to update the position of the typing indicator.
    [self.view setNeedsUpdateConstraints];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (decelerate) return;
    [self configurePaginationWindow];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self configurePaginationWindow];
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    [self configurePaginationWindow];
}

#pragma mark - Reusable View Configuration

/**
 Atlas - Extracting the proper message part and analyzing its properties to determine the cell configuration.
 */
- (void)configureCell:(UICollectionViewCell<ATLMessagePresenting> *)cell forMessage:(LYRMessage *)message indexPath:(NSIndexPath *)indexPath
{
    [cell presentMessage:message];
    BOOL willDisplayAvatarItem = (![message.sender.userID isEqualToString:self.layerClient.authenticatedUser.userID]) ? self.shouldDisplayAvatarItem : (self.shouldDisplayAvatarItem && self.shouldDisplayAvatarItemForAuthenticatedUser);
    [cell shouldDisplayAvatarItem:willDisplayAvatarItem];
    
    if ([self shouldDisplayAvatarItemAtIndexPath:indexPath]) {
        [cell updateWithSender:[self participantForIdentity:message.sender]];
    } else {
        [cell updateWithSender:nil];
    }
    if (message.isUnread && [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive && self.marksMessagesAsRead) {
        [message markAsRead:nil];
    }
}

- (void)configureFooter:(ATLConversationCollectionViewFooter *)footer atIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    footer.message = message;
    if ([self shouldDisplayReadReceiptForSection:indexPath.section]) {
        [footer updateWithAttributedStringForRecipientStatus:[self attributedStringForRecipientStatusOfMessage:message]];
    } else {
        [footer updateWithAttributedStringForRecipientStatus:nil];
    }
}

- (void)configureHeader:(ATLConversationCollectionViewHeader *)header atIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    header.message = message;
    if ([self shouldDisplayDateLabelForSection:indexPath.section]) {
        [header updateWithAttributedStringForDate:[self attributedStringForMessageDate:message]];
    }
    if ([self shouldDisplaySenderLabelForSection:indexPath.section]) {
        NSString *name =[self participantNameForMessage:message];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"hh:mm a"];
        NSString *date = @"";
        if (message.sentAt){
            date = [formatter stringFromDate:message.sentAt];
        }
        //NSString *time = [message.sentAt time]
        [header updateWithParticipantName:[NSString stringWithFormat:@"%@ %@", name, date]];
    }
}

#pragma mark - UI Configuration

- (CGFloat)defaultCellHeightForItemAtIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    if ([message.sender.userID isEqualToString:self.layerClient.authenticatedUser.userID]) {
        return [ATLOutgoingMessageCollectionViewCell cellHeightForMessage:message inView:self.view];
    } else {
        return [ATLIncomingMessageCollectionViewCell cellHeightForMessage:message inView:self.view];
    }
}

- (BOOL)shouldDisplayDateLabelForSection:(NSUInteger)section
{
    if (section < ATLNumberOfSectionsBeforeFirstMessageSection) return NO;
    if (section == ATLNumberOfSectionsBeforeFirstMessageSection) return YES;
    
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    LYRMessage *previousMessage = [self.conversationDataSource messageAtCollectionViewSection:section - 1];
    if (!previousMessage.sentAt) return NO;
    
    NSDate *date = message.sentAt ?: [NSDate date];
    NSTimeInterval interval = [date timeIntervalSinceDate:previousMessage.sentAt];
    if (interval > self.dateDisplayTimeInterval) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldDisplaySenderLabelForSection:(NSUInteger)section
{
    if (self.conversation.participants.count <= 2) return NO;
    
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    if ([message.sender.userID isEqualToString:self.layerClient.authenticatedUser.userID]) return NO;
    if (section > ATLNumberOfSectionsBeforeFirstMessageSection) {
        LYRMessage *previousMessage = [self.conversationDataSource messageAtCollectionViewSection:section - 1];
        if ([previousMessage.sender.userID isEqualToString:message.sender.userID]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)shouldDisplayReadReceiptForSection:(NSUInteger)section
{
    // Only show read receipt if last message was sent by currently authenticated user
    NSInteger lastQueryControllerRow = [self.conversationDataSource.queryController numberOfObjectsInSection:0] - 1;
    NSInteger lastSection = [self.conversationDataSource collectionViewSectionForQueryControllerRow:lastQueryControllerRow];
    if (section != lastSection) return NO;
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    if (![message.sender.userID isEqualToString:self.layerClient.authenticatedUser.userID]) return NO;
    
    return YES;
}

- (BOOL)shouldClusterMessageAtSection:(NSUInteger)section
{
    if (section == self.collectionView.numberOfSections - 1) {
        return NO;
    }
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    LYRMessage *nextMessage = [self.conversationDataSource messageAtCollectionViewSection:section + 1];
    if (!nextMessage.receivedAt) {
        return NO;
    }
    NSDate *date = message.receivedAt ?: [NSDate date];
    NSTimeInterval interval = [nextMessage.receivedAt timeIntervalSinceDate:date];
    return (interval < 60);
}

- (BOOL)shouldDisplayAvatarItemAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.shouldDisplayAvatarItem) return NO;
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    if (message.sender.userID == nil) {
        return NO;
    }
    
    if ([message.sender.userID isEqualToString:self.layerClient.authenticatedUser.userID] && !self.shouldDisplayAvatarItemForAuthenticatedUser) {
        return NO;
    }
    if (![self shouldClusterMessageAtSection:indexPath.section] && self.avatarItemDisplayFrequency == ATLAvatarItemDisplayFrequencyCluster) {
        return YES;
    }
    NSInteger lastQueryControllerRow = [self.conversationDataSource.queryController numberOfObjectsInSection:0] - 1;
    NSInteger lastSection = [self.conversationDataSource collectionViewSectionForQueryControllerRow:lastQueryControllerRow];
    if (indexPath.section < lastSection) {
        LYRMessage *nextMessage = [self.conversationDataSource messageAtCollectionViewSection:indexPath.section + 1];
        // If the next message is sent by the same user, no
        if ([nextMessage.sender.userID isEqualToString:message.sender.userID] && self.avatarItemDisplayFrequency != ATLAvatarItemDisplayFrequencyAll) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - ATLMessageInputToolbarDelegate

- (void)messageInputToolbar:(ATLMessageInputToolbar *)messageInputToolbar didTapLeftAccessoryButton:(UIButton *)leftAccessoryButton
{
    if (messageInputToolbar.textInputView.isFirstResponder) {
        [messageInputToolbar.textInputView resignFirstResponder];
    }
    
    UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:nil
                                                             delegate:self
                                                    cancelButtonTitle:ATLLocalizedString(@"atl.conversation.toolbar.actionsheet.cancel.key", @"Cancel", nil)
                                               destructiveButtonTitle:nil
                                                    otherButtonTitles:ATLLocalizedString(@"atl.conversation.toolbar.actionsheet.takephoto.key", @"Take Photo/Video", nil), ATLLocalizedString(@"atl.conversation.toolbar.actionsheet.lastphoto.key", @"Last Photo/Video", nil), ATLLocalizedString(@"atl.conversation.toolbar.actionsheet.library.key", @"Photo/Video Library", nil), nil];
    [actionSheet showInView:self.view];
    actionSheet.tag = ATLPhotoActionSheet;
}

- (void)messageInputToolbar:(ATLMessageInputToolbar *)messageInputToolbar didTapRightAccessoryButton:(UIButton *)rightAccessoryButton
{
    if (!self.conversation) {
        return;
    }
    
    // If there's no content in the input field, send the location.
    NSOrderedSet *messages = [self messagesForMediaAttachments:messageInputToolbar.mediaAttachments];
    if (messages.count == 0 && messageInputToolbar.textInputView.text.length == 0) {
        //
        
        NSUserDefaults *userDefault = [NSUserDefaults standardUserDefaults];
        NSString *shouldShare = [userDefault stringForKey:@"cape_share_static_location"];
        if(!shouldShare || [shouldShare isEqualToString:@"0"]){
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Share Location" message:@"This will share you static location. If you don't want to share your static location with this friend, tap cancel." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                
                NSUserDefaults *userDefault = [NSUserDefaults standardUserDefaults];
                [userDefault setObject:@"1" forKey:@"cape_share_static_location"];
                [userDefault synchronize];
                
                [self sendLocationMessage];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        }else{
            [self sendLocationMessage];
        }
        
    } else {
        for (LYRMessage *message in messages) {
            [self sendMessage:message];
        }
    }
    
    
    
    if (self.addressBarController) [self.addressBarController disable];
}

- (void)messageInputToolbarDidType:(ATLMessageInputToolbar *)messageInputToolbar
{
    if (!self.conversation) return;
    [self.conversation sendTypingIndicator:LYRTypingDidBegin];
}

- (void)messageInputToolbarDidEndTyping:(ATLMessageInputToolbar *)messageInputToolbar
{
    if (!self.conversation) return;
    [self.conversation sendTypingIndicator:LYRTypingDidFinish];
}

#pragma mark - Message Sending

- (NSOrderedSet *)defaultMessagesForMediaAttachments:(NSArray *)mediaAttachments
{
    NSMutableOrderedSet *messages = [NSMutableOrderedSet new];
    for (ATLMediaAttachment *attachment in mediaAttachments){
        NSArray *messageParts = ATLMessagePartsWithMediaAttachment(attachment);
        LYRMessage *message = [self messageForMessageParts:messageParts MIMEType:attachment.mediaMIMEType pushText:(([attachment.mediaMIMEType isEqualToString:ATLMIMETypeTextPlain]) ? attachment.textRepresentation : nil)];
        if (message)[messages addObject:message];
    }
    return messages;
}

- (LYRMessage *)messageForMessageParts:(NSArray *)parts MIMEType:(NSString *)MIMEType pushText:(NSString *)pushText;
{
    NSString *senderName = [[self participantForIdentity:self.layerClient.authenticatedUser] displayName];
    NSString *completePushText;
    if (!pushText) {
        if ([MIMEType isEqualToString:ATLMIMETypeImageGIF]) {
            completePushText = [NSString stringWithFormat:@"%@ %@", senderName, ATLDefaultPushAlertGIF];
        } else if ([MIMEType isEqualToString:ATLMIMETypeImagePNG] || [MIMEType isEqualToString:ATLMIMETypeImageJPEG]) {
            completePushText = [NSString stringWithFormat:@"%@ %@", senderName, ATLDefaultPushAlertImage];
        } else if ([MIMEType isEqualToString:ATLMIMETypeLocation]) {
            completePushText = [NSString stringWithFormat:@"%@ %@", senderName, ATLDefaultPushAlertLocation];
        } else if ([MIMEType isEqualToString:ATLMIMETypeVideoMP4]){
            completePushText = [NSString stringWithFormat:@"%@ %@", senderName, ATLDefaultPushAlertVideo];
        } else {
            completePushText = [NSString stringWithFormat:@"%@ %@", senderName, ATLDefaultPushAlertText];
        }
    } else {
        completePushText = [NSString stringWithFormat:@"%@: %@", senderName, pushText];
    }
    
    LYRMessage *message = ATLMessageForParts(self.layerClient, parts, completePushText, ATLPushNotificationSoundName);
    return message;
}

- (void)sendMessage:(LYRMessage *)message
{
    NSError *error;
    BOOL success = [self.conversation sendMessage:message error:&error];
    if (success) {
        [self notifyDelegateOfMessageSend:message];
    } else {
        [self notifyDelegateOfMessageSendFailure:message error:error];
    }
}

#pragma mark - Location Message

- (void)sendLocationMessage
{
    self.shouldShareLocation = YES;
    if (!self.locationManager) {
        self.locationManager = [[ATLLocationManager alloc] init];
        self.locationManager.delegate = self;
        if ([self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
            [self.locationManager requestWhenInUseAuthorization];
        }
    }
    if ([self.locationManager locationServicesEnabled]) {
        [self.locationManager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    if (!self.shouldShareLocation) return;
    if (locations.firstObject) {
        self.shouldShareLocation = NO;
        [self sendMessageWithLocation:locations.firstObject];
        [self.locationManager stopUpdatingLocation];
    }
}

- (void)sendMessageWithLocation:(CLLocation *)location
{
    ATLMediaAttachment *attachement = [ATLMediaAttachment mediaAttachmentWithLocation:location];
    LYRMessage *message = [self messageForMessageParts:ATLMessagePartsWithMediaAttachment(attachement) MIMEType:ATLMIMETypeLocation pushText:nil];
    [self sendMessage:message];
}

#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (actionSheet.tag == ATLPhotoActionSheet) {
        switch (buttonIndex) {
            case 0:
                [self displayImagePickerWithSourceType:UIImagePickerControllerSourceTypeCamera];
                break;
                
            case 1:
                [self captureLastPhotoTaken];
                break;
                
            case 2:
                [self displayImagePickerWithSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
                break;
                
            default:
                break;
        }
    }
}

#pragma mark - Image Picking

- (void)displayImagePickerWithSourceType:(UIImagePickerControllerSourceType)sourceType;
{
    [self.messageInputToolbar.textInputView resignFirstResponder];
    BOOL pickerSourceTypeAvailable = [UIImagePickerController isSourceTypeAvailable:sourceType];
    if (pickerSourceTypeAvailable) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:sourceType];
        picker.sourceType = sourceType;
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        [self.navigationController presentViewController:picker animated:YES completion:nil];
    }
}

- (void)captureLastPhotoTaken
{
    ATLAssetURLOfLastPhotoTaken(^(NSURL *assetURL, NSError *error) {
        if (error) {
            NSLog(@"Failed to capture last photo with error: %@", [error localizedDescription]);
        } else {
            ATLMediaAttachment *mediaAttachment = [ATLMediaAttachment mediaAttachmentWithAssetURL:assetURL thumbnailSize:ATLDefaultThumbnailSize];
            [self.messageInputToolbar insertMediaAttachment:mediaAttachment withEndLineBreak:YES];
        }
    });
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    ATLMediaAttachment *mediaAttachment;
    if (info[UIImagePickerControllerMediaURL]) {
        // Video recorded within the app or was picked and edited in
        // the image picker.
        NSURL *moviePath = [NSURL fileURLWithPath:(NSString *)[[info objectForKey:UIImagePickerControllerMediaURL] path]];
        mediaAttachment = [ATLMediaAttachment mediaAttachmentWithFileURL:moviePath thumbnailSize:ATLDefaultThumbnailSize];
    } else if (info[UIImagePickerControllerReferenceURL]) {
        // Photo taken or video recorded within the app.
        mediaAttachment = [ATLMediaAttachment mediaAttachmentWithAssetURL:info[UIImagePickerControllerReferenceURL] thumbnailSize:ATLDefaultThumbnailSize];
    } else if (info[UIImagePickerControllerOriginalImage]) {
        // Image picked from the image picker.
        mediaAttachment = [ATLMediaAttachment mediaAttachmentWithImage:info[UIImagePickerControllerOriginalImage] metadata:info[UIImagePickerControllerMediaMetadata] thumbnailSize:ATLDefaultThumbnailSize];
    } else {
        return;
    }
    
    if (mediaAttachment) {
        [self.messageInputToolbar insertMediaAttachment:mediaAttachment withEndLineBreak:YES];
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    [self.view becomeFirstResponder];
    
    // Workaround for collection view not displayed on iOS 7.1.
    [self.collectionView setNeedsLayout];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    [self.view becomeFirstResponder];
    
    // Workaround for collection view not displayed on iOS 7.1.
    [self.collectionView setNeedsLayout];
}

#pragma mark - Notification Handlers

- (void)didReceiveTypingIndicator:(NSNotification *)notification
{
    if (!self.conversation) return;
    if (!notification.object) return;
    if (![notification.object isEqual:self.conversation]) return;
    
    NSString *participantID = notification.userInfo[LYRTypingIndicatorParticipantUserInfoKey];
    NSNumber *statusNumber = notification.userInfo[LYRTypingIndicatorValueUserInfoKey];
    LYRTypingIndicator status = statusNumber.unsignedIntegerValue;
    if (status == LYRTypingDidBegin) {
        [self.typingParticipantIDs addObject:participantID];
    } else {
        [self.typingParticipantIDs removeObject:participantID];
    }
    [self updateTypingIndicatorOverlay:YES];
}

- (void)layerClientObjectsDidChange:(NSNotification *)notification
{
    if (!self.conversation) return;
    if (!self.layerClient) return;
    if (!notification.object) return;
    if (![notification.object isEqual:self.layerClient]) return;
    
    NSArray *changes = notification.userInfo[LYRClientObjectChangesUserInfoKey];
    for (LYRObjectChange *change in changes) {
        if (![change.object isEqual:self.conversation]) {
            continue;
        }
        if (change.type == LYRObjectChangeTypeUpdate && [change.property isEqualToString:@"participants"]) {
            [self configureControllerForChangedParticipants];
            break;
        }
    }
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification
{
    if (self.conversation && self.marksMessagesAsRead) {
        NSError *error;
        BOOL success = [self.conversation markAllMessagesAsRead:&error];
        if (!success) {
            NSLog(@"Failed to mark all messages as read with error: %@", error);
        }
    }
}

#pragma mark - Typing Indicator

- (void)updateTypingIndicatorOverlay:(BOOL)animated
{
    NSMutableOrderedSet *knownParticipantsTyping = [NSMutableOrderedSet new];
    [self.typingParticipantIDs enumerateObjectsUsingBlock:^(NSString *participantID, NSUInteger idx, BOOL *stop) {
        LYRIdentity *identity = ATLIdentityFromSet(participantID, self.conversation.participants);
        id<ATLParticipant> participant = [self participantForIdentity:identity];
        if (participant) [knownParticipantsTyping addObject:participant];
    }];
    [self.typingIndicatorController updateWithParticipants:knownParticipantsTyping animated:animated];
    
    if (knownParticipantsTyping.count) {
        self.typingIndicatorInset = self.typingIndicatorController.view.frame.size.height;
    } else {
        self.typingIndicatorInset = 0.0f;
    }
}

#pragma mark - Controller Configuration For Changed Participants

- (void)configureControllerForChangedParticipants
{
    if (self.addressBarController && ![self.addressBarController isDisabled]) {
        [self configureConversationForAddressBar];
        return;
    }
    NSMutableSet *removedParticipantIdentifiers = [NSMutableSet setWithArray:[self.typingParticipantIDs array]];
    if (removedParticipantIdentifiers.count) {
        [removedParticipantIdentifiers minusSet:self.conversation.participants];
        [self.typingParticipantIDs removeObjectsInArray:removedParticipantIdentifiers.allObjects];
        [self updateTypingIndicatorOverlay:NO];
    }
    [self configureAddressBarForChangedParticipants];
    [self configureControllerForConversation];
    [self.collectionView reloadData];
}

#pragma mark - Device Rotation

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.collectionView.collectionViewLayout invalidateLayout];
}

#pragma mark - ATLAddressBarViewControllerDelegate

- (void)addressBarViewControllerDidBeginSearching:(ATLAddressBarViewController *)addressBarViewController
{
    self.messageInputToolbar.hidden = YES;
}

- (void)addressBarViewControllerDidEndSearching:(ATLAddressBarViewController *)addressBarViewController
{
    self.messageInputToolbar.hidden = NO;
}

- (void)addressBarViewController:(ATLAddressBarViewController *)addressBarViewController didSelectParticipant:(id<ATLParticipant>)participant
{
    self.canDisableAddressBar = NO;
    [self configureConversationForAddressBar];
}

- (void)addressBarViewController:(ATLAddressBarViewController *)addressBarViewController didRemoveParticipant:(id<ATLParticipant>)participant
{
    [self configureConversationForAddressBar];
}

#pragma mark - Pagination

- (void)configurePaginationWindow
{
    if (CGRectEqualToRect(self.collectionView.frame, CGRectZero)) return;
    if (self.collectionView.isDragging) return;
    if (self.collectionView.isDecelerating) return;
    
    CGFloat topOffset = -self.collectionView.contentInset.top;
    CGFloat distanceFromTop = self.collectionView.contentOffset.y - topOffset;
    CGFloat minimumDistanceFromTopToTriggerLoadingMore = 200;
    BOOL nearTop = distanceFromTop <= minimumDistanceFromTopToTriggerLoadingMore;
    if (!nearTop) return;
    
    self.expandingPaginationWindow = YES;
    [self.conversationDataSource expandPaginationWindow];
}

- (void)configureMoreMessagesIndicatorVisibility
{
    if (self.collectionView.isDragging) return;
    if (self.collectionView.isDecelerating) return;
    BOOL moreMessagesAvailable = [self.conversationDataSource moreMessagesAvailable];
    if (moreMessagesAvailable == self.showingMoreMessagesIndicator) return;
    self.showingMoreMessagesIndicator = moreMessagesAvailable;
    [self reloadCollectionViewAdjustingForContentHeightChange];
}

- (void)reloadCollectionViewAdjustingForContentHeightChange
{
    CGFloat priorContentHeight = self.collectionView.contentSize.height;
    [self.collectionView reloadData];
    CGFloat contentHeightDifference = self.collectionView.collectionViewLayout.collectionViewContentSize.height - priorContentHeight;
    CGFloat adjustment = contentHeightDifference;
    self.collectionView.contentOffset = CGPointMake(0, self.collectionView.contentOffset.y + adjustment);
    [self.collectionView flashScrollIndicators];
}

#pragma mark - Conversation Configuration

- (void)configureConversationForAddressBar
{
    NSSet *participants = self.addressBarController.selectedParticipants.set;
    NSSet *participantIdentifiers = [participants valueForKey:@"userID"];
    
    if (!participantIdentifiers && !self.conversation.participants) return;
    
    NSString *authenticatedUserID = self.layerClient.authenticatedUser.userID;
    NSMutableSet *conversationParticipantsCopy = [[self.conversation.participants valueForKey:@"userID"] mutableCopy];
    if ([conversationParticipantsCopy containsObject:authenticatedUserID]) {
        [conversationParticipantsCopy removeObject:authenticatedUserID];
    }
    if ([participantIdentifiers isEqual:conversationParticipantsCopy]) return;
    
    LYRConversation *conversation = [self conversationWithParticipants:participants];
    self.conversation = conversation;
}

#pragma mark - Address Bar Configuration

- (void)configureAddressBarForChangedParticipants
{
    if (!self.addressBarController) return;
    
    NSOrderedSet *existingParticipants = self.addressBarController.selectedParticipants;
    NSOrderedSet *existingParticipantIdentifiers = [existingParticipants valueForKey:@"userID"];
    
    if (!existingParticipantIdentifiers && !self.conversation.participants) return;
    if ([existingParticipantIdentifiers.set isEqual:[self.conversation.participants valueForKey:@"userID"]]) return;
    
    NSMutableOrderedSet *removedIdentifiers = [NSMutableOrderedSet orderedSetWithOrderedSet:existingParticipantIdentifiers];
    [removedIdentifiers minusSet:[self.conversation.participants valueForKey:@"userID"]];
    
    NSMutableOrderedSet *addedIdentifiers = [NSMutableOrderedSet orderedSetWithSet:[self.conversation.participants valueForKey:@"userID"]];
    [addedIdentifiers minusOrderedSet:existingParticipantIdentifiers];
    
    NSString *authenticatedUserID = self.layerClient.authenticatedUser.userID;
    if (authenticatedUserID) [addedIdentifiers removeObject:authenticatedUserID];
    
    NSMutableOrderedSet *participantIdentifiers = [NSMutableOrderedSet orderedSetWithOrderedSet:existingParticipantIdentifiers];
    [participantIdentifiers minusOrderedSet:removedIdentifiers];
    [participantIdentifiers unionOrderedSet:addedIdentifiers];
    
    NSOrderedSet *participants = [self participantsForIdentifiers:participantIdentifiers];
    self.addressBarController.selectedParticipants = participants;
}

#pragma mark - Public Methods

- (void)registerClass:(Class<ATLMessagePresenting>)cellClass forMessageCellWithReuseIdentifier:(NSString *)reuseIdentifier
{
    [self.collectionView registerClass:cellClass forCellWithReuseIdentifier:reuseIdentifier];
}

- (void)reloadCellForMessage:(LYRMessage *)message
{
    dispatch_async(self.animationQueue, ^{
        NSIndexPath *indexPath = [self.conversationDataSource.queryController indexPathForObject:message];
        if (indexPath) {
            NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:indexPath];
            if (collectionViewIndexPath) {
                // Configure the cell, the header, and the footer
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self configureCollectionViewElementsAtCollectionViewIndexPath:collectionViewIndexPath];
                });
            }
        }
    });
}

- (void)reloadCellsForMessagesSentByParticipantWithIdentifier:(NSString *)participantIdentifier
{
    if (self.conversationDataSource.queryController.query == nil) {
        return;
    }
    
    dispatch_async(self.animationQueue, ^{
        // Query for all of the message identifiers in the conversation
        LYRQuery *messageIdentifiersQuery = [self.conversationDataSource.queryController.query copy];
        if (messageIdentifiersQuery == nil) {
            return;
        }
        messageIdentifiersQuery.resultType = LYRQueryResultTypeIdentifiers;
        NSError *error = nil;
        NSOrderedSet *messageIdentifiers = [self.layerClient executeQuery:messageIdentifiersQuery error:&error];
        if (!messageIdentifiers) {
            NSLog(@"LayerKit failed to execute query with error: %@", error);
            return;
        }
        
        // Query for the all of the message identifiers in the above set where user == participantIdentifier
        LYRQuery *query = [LYRQuery queryWithQueryableClass:[LYRMessage class]];
        LYRPredicate *senderPredicate = [LYRPredicate predicateWithProperty:@"sender.userID" predicateOperator:LYRPredicateOperatorIsEqualTo value:participantIdentifier];
        LYRPredicate *objectIdentifiersPredicate = [LYRPredicate predicateWithProperty:@"identifier" predicateOperator:LYRPredicateOperatorIsIn value:messageIdentifiers];
        query.predicate = [LYRCompoundPredicate compoundPredicateWithType:LYRCompoundPredicateTypeAnd subpredicates:@[ senderPredicate, objectIdentifiersPredicate ]];
        query.resultType = LYRQueryResultTypeIdentifiers;
        NSOrderedSet *messageIdentifiersToReload = [self.layerClient executeQuery:query error:&error];
        if (!messageIdentifiers) {
            NSLog(@"LayerKit failed to execute query with error: %@", error);
            return;
        }
        
        // Convert query controller index paths to collection view index paths
        NSDictionary *objectIdentifiersToIndexPaths = [self.conversationDataSource.queryController indexPathsForObjectsWithIdentifiers:messageIdentifiersToReload.set];
        NSArray *queryControllerIndexPaths = [objectIdentifiersToIndexPaths allValues];
        for (NSIndexPath *indexPath in queryControllerIndexPaths) {
            NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:indexPath];
            // Configure the cell, the header, and the footer
            dispatch_async(dispatch_get_main_queue(), ^{
                [self configureCollectionViewElementsAtCollectionViewIndexPath:collectionViewIndexPath];
            });
        }
    });
}

#pragma mark - Delegate

- (void)notifyDelegateOfMessageSend:(LYRMessage *)message
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didSendMessage:)]) {
        [self.delegate conversationViewController:self didSendMessage:message];
    }
}

- (void)notifyDelegateOfMessageSendFailure:(LYRMessage *)message error:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didFailSendingMessage:error:)]) {
        [self.delegate conversationViewController:self didFailSendingMessage:message error:error];
    }
}

- (void)notifyDelegateOfMessageSelection:(LYRMessage *)message
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didSelectMessage:)]) {
        [self.delegate conversationViewController:self didSelectMessage:message];
    }
}

- (CGSize)heightForMessageAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat width = self.collectionView.bounds.size.width;
    CGFloat height = 0;
    if ([self.delegate respondsToSelector:@selector(conversationViewController:heightForMessage:withCellWidth:)]) {
        LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
        height = [self.delegate conversationViewController:self heightForMessage:message withCellWidth:width];
    }
    if (!height) {
        height = [self defaultCellHeightForItemAtIndexPath:indexPath];
    }
    return CGSizeMake(width, height);
}

- (NSOrderedSet *)messagesForMediaAttachments:(NSArray *)mediaAttachments
{
    NSOrderedSet *messages;
    if ([self.delegate respondsToSelector:@selector(conversationViewController:messagesForMediaAttachments:)]) {
        messages = [self.delegate conversationViewController:self messagesForMediaAttachments:mediaAttachments];
        // If delegate returns an empty set, don't send any messages.
        if (messages && !messages.count) return nil;
    }
    // If delegate returns nil, we fall back to default behavior.
    if (!messages) messages = [self defaultMessagesForMediaAttachments:mediaAttachments];
    return messages;
}

#pragma mark - Data Source

- (id<ATLParticipant>)participantForIdentity:(LYRIdentity *)identity;
{
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:participantForIdentity:)]) {
        return [self.dataSource conversationViewController:self participantForIdentity:identity];
    } else {
        return identity;
    }
}

- (NSAttributedString *)attributedStringForMessageDate:(LYRMessage *)message
{
    NSAttributedString *dateString;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:attributedStringForDisplayOfDate:)]) {
        NSDate *date = message.sentAt ?: [NSDate date];
        dateString = [self.dataSource conversationViewController:self attributedStringForDisplayOfDate:date];
        NSAssert([dateString isKindOfClass:[NSAttributedString class]], @"Date string must be an attributed string");
    } else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"ATLConversationViewControllerDataSource must return an attributed string for Date" userInfo:nil];
    }
    return dateString;
}

- (NSAttributedString *)attributedStringForRecipientStatusOfMessage:(LYRMessage *)message
{
    NSAttributedString *recipientStatusString;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:attributedStringForDisplayOfRecipientStatus:)]) {
        recipientStatusString = [self.dataSource conversationViewController:self attributedStringForDisplayOfRecipientStatus:message.recipientStatusByUserID];
        NSAssert([recipientStatusString isKindOfClass:[NSAttributedString class]], @"Recipient String must be an attributed string");
    } else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"ATLConversationViewControllerDataSource must return an attributed string for recipient status" userInfo:nil];
    }
    return recipientStatusString;
}

- (NSString *)reuseIdentifierForMessage:(LYRMessage *)message atIndexPath:(NSIndexPath *)indexPath
{
    NSString *reuseIdentifier;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:reuseIdentifierForMessage:)]) {
        reuseIdentifier = [self.dataSource conversationViewController:self reuseIdentifierForMessage:message];
    }
    if (!reuseIdentifier) {
        if ([self.layerClient.authenticatedUser.userID isEqualToString:message.sender.userID]) {
            reuseIdentifier = ATLOutgoingMessageCellIdentifier;
        } else {
            reuseIdentifier = ATLIncomingMessageCellIdentifier;
        }
    }
    return reuseIdentifier;
}

- (LYRConversation *)conversationWithParticipants:(NSSet *)participants
{
    if (participants.count == 0) return nil;
    
    LYRConversation *conversation;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:conversationWithParticipants:)]) {
        conversation = [self.dataSource conversationViewController:self conversationWithParticipants:participants];
        if (conversation) return conversation;
    }
    NSSet *participantIdentifiers = [participants valueForKey:@"userID"];
    conversation = [self existingConversationWithParticipantIdentifiers:participantIdentifiers];
    if (conversation) return conversation;
    
    BOOL deliveryReceiptsEnabled = participants.count <= 5;
    NSDictionary *options = @{LYRConversationOptionsDeliveryReceiptsEnabledKey: @(deliveryReceiptsEnabled)};
    conversation = [self.layerClient newConversationWithParticipants:participantIdentifiers options:options error:nil];
    return conversation;
}

#pragma mark - LYRQueryControllerDelegate

- (void)queryController:(LYRQueryController *)controller
        didChangeObject:(id)object
            atIndexPath:(NSIndexPath *)indexPath
          forChangeType:(LYRQueryControllerChangeType)type
           newIndexPath:(NSIndexPath *)newIndexPath
{
    if (self.expandingPaginationWindow) return;
    NSInteger currentIndex = indexPath ? [self.conversationDataSource collectionViewSectionForQueryControllerRow:indexPath.row] : NSNotFound;
    NSInteger newIndex = newIndexPath ? [self.conversationDataSource collectionViewSectionForQueryControllerRow:newIndexPath.row] : NSNotFound;
    [self.objectChanges addObject:[ATLDataSourceChange changeObjectWithType:type newIndex:newIndex currentIndex:currentIndex]];
}

- (void)queryControllerWillChangeContent:(LYRQueryController *)queryController
{
    // Implemented by subclass
}

- (void)queryControllerDidChangeContent:(LYRQueryController *)queryController
{
    NSArray *objectChanges = [self.objectChanges copy];
    [self.objectChanges removeAllObjects];
    
    if (self.expandingPaginationWindow) {
        self.expandingPaginationWindow = NO;
        self.showingMoreMessagesIndicator = [self.conversationDataSource moreMessagesAvailable];
        [self reloadCollectionViewAdjustingForContentHeightChange];
        return;
    }
    
    if (objectChanges.count == 0) {
        [self configurePaginationWindow];
        [self configureMoreMessagesIndicatorVisibility];
        return;
    }
    
    // Prevent scrolling if user has scrolled up into the conversation history.
    BOOL shouldScrollToBottom = [self shouldScrollToBottom];
    
    // ensure the animation's queue will resume
    if (self.collectionView) {
        dispatch_suspend(self.animationQueue);
        [self.collectionView performBatchUpdates:^{
            for (ATLDataSourceChange *change in objectChanges) {
                switch (change.type) {
                    case LYRQueryControllerChangeTypeInsert:
                        [self.collectionView insertSections:[NSIndexSet indexSetWithIndex:change.newIndex]];
                        break;
                        
                    case LYRQueryControllerChangeTypeMove:
                        [self.collectionView moveSection:change.currentIndex toSection:change.newIndex];
                        break;
                        
                    case LYRQueryControllerChangeTypeDelete:
                        [self.collectionView deleteSections:[NSIndexSet indexSetWithIndex:change.currentIndex]];
                        break;
                        
                    case LYRQueryControllerChangeTypeUpdate:
                        // If we call reloadSections: for a section that is already being animated due to another move (e.g. moving section 17 to 16 causes section 16 to be moved/animated to 17 and then we also reload section 16), UICollectionView will throw an exception. But since all onscreen sections will be reconfigured (see below) we don't need to reload the sections here anyway.
                        break;
                        
                    default:
                        break;
                }
            }
        } completion:^(BOOL finished) {
            dispatch_resume(self.animationQueue);
        }];
    }
    [self configureCollectionViewElements];
    
    if (shouldScrollToBottom)  {
        // We can't get the content size from the collection view because it will be out-of-date due to the above updates, but we can get the update-to-date size from the layout.
        CGSize contentSize = self.collectionView.collectionViewLayout.collectionViewContentSize;
        [self.collectionView setContentOffset:[self bottomOffsetForContentSize:contentSize] animated:YES];
    } else {
        [self configurePaginationWindow];
        [self configureMoreMessagesIndicatorVisibility];
    }
}

- (void)configureCollectionViewElements
{
    // Since each section's content depends on other messages, we need to update each visible section even when a section's corresponding message has not changed. This also solves the issue with LYRQueryControllerChangeTypeUpdate (see above).
    for (UICollectionViewCell<ATLMessagePresenting> *cell in [self.collectionView visibleCells]) {
        NSIndexPath *indexPath = [self.collectionView indexPathForCell:cell];
        LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
        [self configureCell:cell forMessage:message indexPath:indexPath];
    }
    
    for (ATLConversationCollectionViewHeader *header in self.sectionHeaders) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:header.message];
        if (!queryControllerIndexPath) continue;
        NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
        [self configureHeader:header atIndexPath:collectionViewIndexPath];
    }
    
    for (ATLConversationCollectionViewFooter *footer in self.sectionFooters) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:footer.message];
        if (!queryControllerIndexPath) continue;
        NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
        [self configureFooter:footer atIndexPath:collectionViewIndexPath];
    }
}

- (void)configureCollectionViewElementsAtCollectionViewIndexPath:(NSIndexPath *)collectionViewIndexPath {
    // Direct access to the message
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:collectionViewIndexPath];
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:collectionViewIndexPath];
    if ([cell conformsToProtocol:@protocol(ATLMessagePresenting)]) {
        [self configureCell:(UICollectionViewCell<ATLMessagePresenting> *)cell forMessage:message indexPath:collectionViewIndexPath];
    }
    
    // Find the header...
    for (ATLConversationCollectionViewHeader *header in self.sectionHeaders) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:header.message];
        if (queryControllerIndexPath && [header.message.identifier isEqual:message.identifier]) {
            NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
            [self configureHeader:header atIndexPath:collectionViewIndexPath];
            break;
        }
    }
    
    // ...and the footer
    for (ATLConversationCollectionViewFooter *footer in self.sectionFooters) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:footer.message];
        if (queryControllerIndexPath && [footer.message.identifier isEqual:message.identifier]) {
            NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
            [self configureFooter:footer atIndexPath:collectionViewIndexPath];
            break;
        }
    }
}

#pragma mark - Helpers

- (LYRConversation *)existingConversationWithParticipantIdentifiers:(NSSet *)participantIdentifiers
{
    NSMutableSet *set = [participantIdentifiers mutableCopy];
    [set addObject:self.layerClient.authenticatedUser.userID];
    LYRQuery *query = [LYRQuery queryWithQueryableClass:[LYRConversation class]];
    query.predicate = [LYRPredicate predicateWithProperty:@"participants" predicateOperator:LYRPredicateOperatorIsEqualTo value:set];
    query.limit = 1;
    return [self.layerClient executeQuery:query error:nil].lastObject;
}

- (NSOrderedSet *)participantsForIdentifiers:(NSOrderedSet *)identifiers
{
    NSMutableOrderedSet *participants = [NSMutableOrderedSet new];
    for (NSString *participantIdentifier in identifiers) {
        LYRIdentity *identity = ATLIdentityFromSet(participantIdentifier, self.conversation.participants);
        id<ATLParticipant> participant = [self participantForIdentity:identity];
        if (!participant) continue;
        [participants addObject:participant];
    }
    return participants;
}

- (NSString *)participantNameForMessage:(LYRMessage *)message
{
    NSString *participantName;
    if (message.sender.userID) {
        id<ATLParticipant> participant = [self participantForIdentity:message.sender];
        participantName = participant.displayName ?: ATLLocalizedString(@"atl.conversation.participant.unknown.key", @"Unknown User", nil);
    } else {
        participantName = message.sender.displayName;
    }
    return participantName;
}

#pragma mark - NSNotification Center Registration

- (void)atl_registerForNotifications
{
    // Layer Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveTypingIndicator:) name:LYRConversationDidReceiveTypingIndicatorNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(layerClientObjectsDidChange:) name:LYRClientObjectsDidChangeNotification object:nil];
    
    // Application State Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
}

@end
