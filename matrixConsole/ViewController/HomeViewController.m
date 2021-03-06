/*
 Copyright 2015 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "HomeViewController.h"

#import "AppDelegate.h"

#import "RageShakeManager.h"

NSString *const kHomeViewControllerCreateRoomCellId = @"kHomeViewControllerCreateRoomCellId";

@interface HomeViewController ()
{
    // Room creation section
    NSInteger createRoomSection;
    MXKRoomCreationView *createRoomView;
    
    // Join room by alias section
    NSInteger joinRoomSection;
    MXKTableViewCellWithTextFieldAndButton* joinRoomCell;
    
    // Public rooms sections
    NSInteger publicRoomsFirstSection;
    // Homeserver list
    NSMutableArray *homeServers;
    // All registered REST clients
    NSMutableArray *restClients;
    // REST clients by homeserver
    NSMutableDictionary *restClientDict;
    // Public rooms by homeserver
    NSMutableDictionary *publicRoomsDict;
    // Array of shrinked homeservers.
    NSMutableArray *shrinkedHomeServers;
    // Count current refresh requests
    NSInteger refreshCount;
    
    // List of public room names to highlight in displayed list
    NSArray* highlightedPublicRooms;
    
    // Search in public rooms
    UIBarButtonItem *searchButton;
    BOOL             ignoreSearchRequest;
    NSMutableDictionary  *filteredPublicRoomsDict;
}

@end

@implementation HomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Set rageShake handler
    self.rageShakeManager = [RageShakeManager sharedManager];
    
    // Prepare room creation section
    createRoomView = [MXKRoomCreationView roomCreationView];
    createRoomView.delegate = self;
    
    // Init
    highlightedPublicRooms = @[@"#matrix:matrix.org", @"#matrix-dev:matrix.org", @"#matrix-fr:matrix.org"]; // Add here a room name to highlight its display in public room list
    
    // Adjust Top and Bottom constraints to take into account potential navBar and tabBar.
    if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)])
    {
        [NSLayoutConstraint deactivateConstraints:@[_publicRoomsSearchBarTopConstraint, _tableViewBottomConstraint]];
    }
    else
    {
        [self.view removeConstraint:_publicRoomsSearchBarTopConstraint];
        [self.view removeConstraint:_tableViewBottomConstraint];
    }
    
    _publicRoomsSearchBarTopConstraint = [NSLayoutConstraint constraintWithItem:self.topLayoutGuide
                                                                      attribute:NSLayoutAttributeBottom
                                                                      relatedBy:NSLayoutRelationEqual
                                                                         toItem:_publicRoomsSearchBar
                                                                      attribute:NSLayoutAttributeTop
                                                                     multiplier:1.0f
                                                                       constant:0.0f];
    
    _tableViewBottomConstraint = [NSLayoutConstraint constraintWithItem:self.bottomLayoutGuide
                                                              attribute:NSLayoutAttributeTop
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:self.tableView
                                                              attribute:NSLayoutAttributeBottom
                                                             multiplier:1.0f
                                                               constant:0.0f];
    
    if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)])
    {
        [NSLayoutConstraint activateConstraints:@[_publicRoomsSearchBarTopConstraint, _tableViewBottomConstraint]];
    }
    else
    {
        [self.view addConstraint:_publicRoomsSearchBarTopConstraint];
        [self.view addConstraint:_tableViewBottomConstraint];
    }
    
    // Hide search bar by default
    _publicRoomsSearchBar.hidden = YES;
    _publicRoomsSearchBarHeightConstraint.constant = 0;
    [self.view setNeedsUpdateConstraints];
    
    // Add search option in navigation bar
    self.enableSearch = YES;
    
    // Add an accessory view to the search bar in order to retrieve keyboard view.
    _publicRoomsSearchBar.inputAccessoryView = [[UIView alloc] initWithFrame:CGRectZero];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dealloc{
    highlightedPublicRooms = nil;
    _publicRoomsSearchBar.inputAccessoryView = nil;
    searchButton = nil;
    
    [self destroy];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    // Restore search mechanism (if enabled)
    ignoreSearchRequest = NO;
    
    // Refresh all listed public rooms
    [self refreshPublicRooms:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    // The user may still press search button whereas the view disappears
    ignoreSearchRequest = YES;
    
    // Leave potential search session
    if (!_publicRoomsSearchBar.isHidden)
    {
        [self searchBarCancelButtonClicked:_publicRoomsSearchBar];
    }
}

#pragma mark - Override MXKViewController

- (void)stopActivityIndicator
{
    // Check whether public rooms refresh is in progress
    if (refreshCount)
    {
        return;
    }
    
    [super stopActivityIndicator];
}

- (void)onKeyboardShowAnimationComplete
{
    // Check first if the search bar is the first responder
    UIView *keyboardView = _publicRoomsSearchBar.inputAccessoryView.superview;
    if (!keyboardView)
    {
        // Check other potential first responder
        keyboardView = joinRoomCell.inputAccessoryView.superview;
        
        if (!keyboardView)
        {
            keyboardView = createRoomView.inputAccessoryView.superview;
        }
    }
    
    // Report the keyboard view in order to track keyboard frame changes
    self.keyboardView = keyboardView;
}

- (void)setKeyboardHeight:(CGFloat)keyboardHeight
{
    
    // Deduce the bottom constraint for the table view (Don't forget the potential tabBar)
    CGFloat tableViewBottomConst = keyboardHeight - self.bottomLayoutGuide.length;
    // Check whether the keyboard is over the tabBar
    if (tableViewBottomConst < 0)
    {
        tableViewBottomConst = 0;
    }
    
    // Update constraints
    _tableViewBottomConstraint.constant = tableViewBottomConst;
    
    // Force layout immediately to take into account new constraint
    [self.view layoutIfNeeded];
}

- (void)destroy
{
    [createRoomView removeFromSuperview];
    [createRoomView destroy];
    
    homeServers = nil;
    restClients = nil;
    restClientDict = nil;
    publicRoomsDict = nil;
    filteredPublicRoomsDict = nil;
    shrinkedHomeServers = nil;
    
    [super destroy];
}

- (void)addMatrixSession:(MXSession *)mxSession
{
    [super addMatrixSession:mxSession];
    
    // Report the related REST Client to retrieve public rooms
    [self addRestClient:mxSession.matrixRestClient];
    
    [self.tableView reloadData];
}

- (void)removeMatrixSession:(MXSession *)mxSession
{
    [super removeMatrixSession:mxSession];
    
    // Remove the related REST Client
    if (mxSession.matrixRestClient)
    {
        [self removeRestClient:mxSession.matrixRestClient];
    }
    else
    {
        // Here the matrix session is closed, the rest client reference has been removed.
        // Force a full refresh
        [self refreshPublicRooms:nil];
    }
    
    [self.tableView reloadData];
}

#pragma mark -

- (void)addRestClient:(MXRestClient*)restClient
{
    if (!restClient.homeserver)
    {
        return;
    }
    
    if (!homeServers)
    {
        homeServers = [NSMutableArray array];
    }
    if (!restClients)
    {
        restClients = [NSMutableArray array];
    }
    if (!restClientDict)
    {
        restClientDict = [NSMutableDictionary dictionary];
    }
    
    if ([restClients indexOfObject:restClient] == NSNotFound)
    {
        [restClients addObject:restClient];
        
        if ([homeServers indexOfObject:restClient.homeserver] == NSNotFound){
            [homeServers addObject:restClient.homeserver];
            [restClientDict setObject:restClient forKey:restClient.homeserver];
            [self refreshPublicRooms:restClient];
        }
    }
}

- (void)removeRestClient:(MXRestClient *)restClient
{
    NSUInteger index = [restClients indexOfObject:restClient];
    if (index != NSNotFound)
    {
        [restClients removeObjectAtIndex:index];
        
        // Check whether this client was reported in rest client dictionary
        for (NSString *homeserver in homeServers)
        {
            if ([restClientDict objectForKey:homeserver] == restClient)
            {
                [restClientDict removeObjectForKey:homeserver];
                BOOL removeHomeServer = YES;
                
                // Look for an other rest client for this homeserver (if any)
                for (MXRestClient *client in restClients)
                {
                    if ([client.homeserver isEqualToString:homeserver])
                    {
                        [restClientDict setObject:client forKey:homeserver];
                        removeHomeServer = NO;
                        break;
                    }
                }
                
                if (removeHomeServer)
                {
                    [homeServers removeObject:homeserver];
                    [publicRoomsDict removeObjectForKey:homeserver];
                }
                
                [self refreshPublicRooms:nil];
                break;
            }
        }
    }
}

- (void)setEnableSearch:(BOOL)enableSearch
{
    if (enableSearch)
    {
        if (!searchButton)
        {
            searchButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(search:)];
        }
        
        // Add it in right bar items
        NSArray *rightBarButtonItems = self.navigationItem.rightBarButtonItems;
        self.navigationItem.rightBarButtonItems = rightBarButtonItems ? [rightBarButtonItems arrayByAddingObject:searchButton] : @[searchButton];
    }
    else
    {
        NSMutableArray *rightBarButtonItems = [NSMutableArray arrayWithArray: self.navigationItem.rightBarButtonItems];
        [rightBarButtonItems removeObject:searchButton];
        self.navigationItem.rightBarButtonItems = rightBarButtonItems;
    }
}

#pragma mark - Internals

- (void)removeClosedRestClients
{
    // We check here all registered clients (Some of them may have been closed).
    for (NSInteger index = 0; index < restClients.count; index ++)
    {
        MXRestClient *restClient = [restClients objectAtIndex:index];
        if (!restClient.homeserver.length)
        {
            [self removeRestClient:restClient];
        }
    }
}

- (void)refreshPublicRooms:(MXRestClient*)restClient
{
    NSArray *selectedClients;
    if (restClient) {
        selectedClients = @[restClient];
    } else {
        // refresh registered clients by removing closed ones.
        [self removeClosedRestClients];
        
        // Consider only one client by homeserver.
        selectedClients = restClientDict.allValues;
    }
    
    if (!selectedClients.count)
    {
        return;
    }
    
    refreshCount += selectedClients.count;
    [self startActivityIndicator];
    
    if (!publicRoomsDict)
    {
        publicRoomsDict = [NSMutableDictionary dictionaryWithCapacity:restClientDict.count];
    }
    if (!shrinkedHomeServers)
    {
        shrinkedHomeServers = [NSMutableArray array];
    }
    
    for (NSInteger index = 0; index < selectedClients.count; index ++)
    {
        MXRestClient *restClient = [selectedClients objectAtIndex:index];
        
        // Retrieve public rooms
        [restClient publicRooms:^(NSArray *rooms){
            NSArray *publicRooms = [rooms sortedArrayUsingComparator:^NSComparisonResult(id a, id b)
            {
                
                MXPublicRoom *firstRoom =  (MXPublicRoom*)a;
                MXPublicRoom *secondRoom = (MXPublicRoom*)b;
                
                // Compare member count
                if (firstRoom.numJoinedMembers < secondRoom.numJoinedMembers)
                {
                    return NSOrderedDescending;
                }
                else if (firstRoom.numJoinedMembers > secondRoom.numJoinedMembers)
                {
                    return NSOrderedAscending;
                }
                else
                {
                    // Alphabetic order
                    return [firstRoom.displayname compare:secondRoom.displayname options:NSCaseInsensitiveSearch];
                }
            }];
            
            if (publicRooms.count && restClient.homeserver)
            {
                [publicRoomsDict setObject:publicRooms forKey:restClient.homeserver];
            }
            
            refreshCount--;
            if (refreshCount == 0)
            {
                [self publicRoomsDidRefresh];
            }
        }
                        failure:^(NSError *error){
                            NSLog(@"[HomeVC] Failed to get public rooms for %@: %@", restClient.homeserver, error);
                            //Alert user
                            [[AppDelegate theDelegate] showErrorAsAlert:error];
                            
                            refreshCount--;
                            if (refreshCount == 0)
                            {
                                [self publicRoomsDidRefresh];
                            }
                        }];
    }
}

- (void)publicRoomsDidRefresh
{
    [self stopActivityIndicator];
    
    // Refresh only the sections related to public rooms (in order to not dismiss potential keyboard).
    NSInteger sectionNb = [self numberOfSectionsInTableView:self.tableView];
    if (publicRoomsFirstSection != -1)
    {
        sectionNb -= publicRoomsFirstSection;
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange (publicRoomsFirstSection, sectionNb)];
        [self.tableView reloadSections:indexSet withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (IBAction)search:(id)sender
{
    // The user may have pressed search button whereas the view controller was disappearing
    if (ignoreSearchRequest)
    {
        return;
    }
    
    if (_publicRoomsSearchBar.isHidden)
    {
        // Check whether there are data in which search
        if (publicRoomsDict.count)
        {
            // Show search bar
            _publicRoomsSearchBar.hidden = NO;
            _publicRoomsSearchBarHeightConstraint.constant = 44;
            [self.view setNeedsUpdateConstraints];
            
            [_publicRoomsSearchBar becomeFirstResponder];
        }
    }
    else
    {
        [self searchBarCancelButtonClicked: _publicRoomsSearchBar];
    }
    
    [self.tableView reloadData];
}

- (void)dismissKeyboard
{
    [createRoomView dismissKeyboard];
    
    [joinRoomCell.mxkTextField resignFirstResponder];
    
    if (_publicRoomsSearchBar)
    {
        [self searchBarCancelButtonClicked: _publicRoomsSearchBar];
    }
}

#pragma mark - MXKRoomCreationView Delegate

- (void)roomCreationView:(MXKRoomCreationView *)creationView presentMXKAlert:(MXKAlert *)alert
{
    [self dismissKeyboard];
    [alert showInViewController:self];
}

- (void)roomCreationView:(MXKRoomCreationView *)creationView showRoom:(NSString *)roomId withMatrixSession:(MXSession *)mxSession
{
    [[AppDelegate theDelegate].masterTabBarController showRoom:roomId withMatrixSession:mxSession];
}

#pragma mark - UITextField delegate

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    if (textField == joinRoomCell.mxkTextField)
    {
        if (textField.text.length == 0)
        {
            textField.text = @"#";
        }
    }
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField == joinRoomCell.mxkTextField)
    {
        if (textField.text.length < 2)
        {
            // reset text field
            textField.text = nil;
            joinRoomCell.mxkButton.enabled = NO;
        }
    }
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    // Auto complete room alias
    if (textField == joinRoomCell.mxkTextField)
    {
        // Add # if none
        if (!textField.text.length || textField.text.length == range.length)
        {
            if ([string hasPrefix:@"#"] == NO)
            {
                textField.text = [NSString stringWithFormat:@"#%@",string];
                // Update Join button status
                joinRoomCell.mxkButton.enabled = YES;
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField*) textField
{
    // "Done" key has been pressed
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Actions

- (IBAction)onButtonPressed:(id)sender
{
    if (sender == joinRoomCell.mxkButton)
    {
        [self dismissKeyboard];
        
        // Handle multi-sessions here
        [[AppDelegate theDelegate] selectMatrixAccount:^(MXKAccount *selectedAccount)
        {
            // Disable button to prevent multiple request
            joinRoomCell.mxkButton.enabled = NO;
            
            NSString *roomAlias = joinRoomCell.mxkTextField.text;
            // Remove white space from both ends
            roomAlias = [roomAlias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            
            // Check
            if (roomAlias.length)
            {
                [selectedAccount.mxSession joinRoom:roomAlias success:^(MXRoom *room)
                {
                    // Reset text fields
                    joinRoomCell.mxkTextField.text = nil;
                    // Show the room
                    [[AppDelegate theDelegate].masterTabBarController showRoom:room.state.roomId withMatrixSession:selectedAccount.mxSession];
                } failure:^(NSError *error)
                {
                    joinRoomCell.mxkButton.enabled = YES;
                    NSLog(@"[HomeVC] Failed to join room alias (%@): %@", roomAlias, error);
                    // Alert user
                    [[AppDelegate theDelegate] showErrorAsAlert:error];
                }];
            }
            else
            {
                // Reset text fields
                joinRoomCell.mxkTextField.text = nil;
            }
        }];
    }
    else if ([sender isKindOfClass:[UIButton class]])
    {
        UIButton *shrinkButton = (UIButton*)sender;
        
        if (shrinkButton.tag < homeServers.count)
        {
            NSString *homeserver = [homeServers objectAtIndex:shrinkButton.tag];
            
            NSUInteger index = [shrinkedHomeServers indexOfObject:homeserver];
            if (index != NSNotFound)
            {
                // Disclose the public rooms list
                [shrinkedHomeServers removeObjectAtIndex:index];
            }
            else
            {
                // Shrink the public rooms list from this homeserver.
                [shrinkedHomeServers addObject:homeserver];
            }
            // Refresh table
            [self.tableView reloadData];
        }
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    NSInteger count = 0;
    
    createRoomSection = joinRoomSection = publicRoomsFirstSection = -1;
    
    // Room creation and join room alias required a matrix session, besides these sections are hidden during search session.
    if (self.mxSessions.count && _publicRoomsSearchBar.isHidden)
    {
        createRoomSection = count++;
        joinRoomSection = count++;
    }
    
    if (homeServers.count)
    {
        publicRoomsFirstSection = count;
        count += homeServers.count;
    }
    return count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger count = 0;
    
    if (section == createRoomSection)
    {
        count = 1;
    }
    else if (section == joinRoomSection)
    {
        count = 1;
    }
    else if (publicRoomsFirstSection != -1)
    {
        NSArray *publicRooms = nil;
        NSInteger index = section - publicRoomsFirstSection;
        if (index < homeServers.count)
        {
            NSString *homeserver = [homeServers objectAtIndex:index];
            
            // Check whether the list is shrinked
            if ([shrinkedHomeServers indexOfObject:homeserver] == NSNotFound)
            {
                if (filteredPublicRoomsDict)
                {
                    publicRooms = [filteredPublicRoomsDict objectForKey:homeserver];
                }
                else
                {
                    publicRooms = [publicRoomsDict objectForKey:homeserver];
                }
            }
        }
        
        count = publicRooms.count;
    }
    return count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == createRoomSection)
    {
        return createRoomView.actualFrameHeight;
    }
    else if ((publicRoomsFirstSection != -1) && (indexPath.section >= publicRoomsFirstSection))
    {
        return 60;
    }
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell;
    
    if (indexPath.section == createRoomSection)
    {
        [createRoomView removeFromSuperview];
        // Update view data
        createRoomView.mxSessions = self.mxSessions;
        
        cell = [tableView dequeueReusableCellWithIdentifier:kHomeViewControllerCreateRoomCellId];
        if (!cell)
        {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kHomeViewControllerCreateRoomCellId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        
        // Add creation view in full size
        [cell.contentView addSubview:createRoomView];
        [cell.contentView addConstraint:[NSLayoutConstraint constraintWithItem:cell.contentView
                                                                     attribute:NSLayoutAttributeBottom
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:createRoomView
                                                                     attribute:NSLayoutAttributeBottom
                                                                    multiplier:1.0f
                                                                      constant:0.0f]];
        [cell.contentView addConstraint:[NSLayoutConstraint constraintWithItem:cell.contentView
                                                                     attribute:NSLayoutAttributeTop
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:createRoomView
                                                                     attribute:NSLayoutAttributeTop
                                                                    multiplier:1.0f
                                                                      constant:0.0f]];
        [cell.contentView addConstraint:[NSLayoutConstraint constraintWithItem:cell.contentView
                                                                     attribute:NSLayoutAttributeLeading
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:createRoomView
                                                                     attribute:NSLayoutAttributeLeading
                                                                    multiplier:1.0f
                                                                      constant:0.0f]];
        [cell.contentView addConstraint:[NSLayoutConstraint constraintWithItem:cell.contentView
                                                                     attribute:NSLayoutAttributeTrailing
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:createRoomView
                                                                     attribute:NSLayoutAttributeTrailing
                                                                    multiplier:1.0f
                                                                      constant:0.0f]];
        [cell.contentView setNeedsUpdateConstraints];
        
    }
    else if (indexPath.section == joinRoomSection)
    {
        // Report the current value (if any)
        NSString *currentAlias = nil;
        if (joinRoomCell)
        {
            currentAlias = joinRoomCell.mxkTextField.text;
        }
        
        joinRoomCell = [tableView dequeueReusableCellWithIdentifier:[MXKTableViewCellWithTextFieldAndButton defaultReuseIdentifier]];
        if (!joinRoomCell)
        {
            joinRoomCell = [[MXKTableViewCellWithTextFieldAndButton alloc] init];
        }
        
        joinRoomCell.mxkTextField.text = currentAlias;
        joinRoomCell.mxkButton.enabled = (currentAlias.length != 0);
        [joinRoomCell.mxkButton setTitle:NSLocalizedStringFromTable(@"join", @"MatrixConsole", nil) forState:UIControlStateNormal];
        [joinRoomCell.mxkButton setTitle:NSLocalizedStringFromTable(@"join", @"MatrixConsole", nil) forState:UIControlStateHighlighted];
        [joinRoomCell.mxkButton addTarget:self action:@selector(onButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        
        cell = joinRoomCell;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else
    {
        MXKPublicRoomTableViewCell *publicRoomCell = [tableView dequeueReusableCellWithIdentifier:[MXKPublicRoomTableViewCell defaultReuseIdentifier]];
        if (!publicRoomCell)
        {
            publicRoomCell = [[MXKPublicRoomTableViewCell alloc] init];
        }
        
        MXPublicRoom *publicRoom;
        NSInteger index = indexPath.section - publicRoomsFirstSection;
        if (index < homeServers.count)
        {
            NSString *homeserver = [homeServers objectAtIndex:index];
            NSArray *publicRooms = nil;
            if (filteredPublicRoomsDict)
            {
                publicRooms = [filteredPublicRoomsDict objectForKey:homeserver];
            }
            else
            {
                publicRooms = [publicRoomsDict objectForKey:homeserver];
            }
            
            if (indexPath.row < publicRooms.count)
            {
                publicRoom = [publicRooms objectAtIndex:indexPath.row];
            }
        }
        
        if (publicRoom)
        {
            [publicRoomCell render:publicRoom];
            // Highlight?
            publicRoomCell.highlightedPublicRoom = (publicRoomCell.roomDisplayName.text && [highlightedPublicRooms indexOfObject:publicRoomCell.roomDisplayName.text] != NSNotFound);
        }
        
        cell = publicRoomCell;
    }
    
    return cell;
}

#pragma mark - Table view delegate

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    // In case of search session, homeservers with no result are hidden.
    if (filteredPublicRoomsDict)
    {
        NSInteger index = section - publicRoomsFirstSection;
        if (index < homeServers.count)
        {
            NSString *homeserver = [homeServers objectAtIndex:index];
            NSArray *publicRooms = [filteredPublicRoomsDict objectForKey:homeserver];
            if (!publicRooms.count)
            {
                return 0;
            }
        }
    }
    return 40;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *sectionHeader = [[UIView alloc] initWithFrame:[tableView rectForHeaderInSection:section]];
    sectionHeader.backgroundColor = [UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0];
    UILabel *sectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 5, sectionHeader.frame.size.width - 10, sectionHeader.frame.size.height - 10)];
    sectionLabel.font = [UIFont boldSystemFontOfSize:16];
    sectionLabel.backgroundColor = [UIColor clearColor];
    [sectionHeader addSubview:sectionLabel];
    
    if (section == createRoomSection)
    {
        sectionLabel.text = NSLocalizedStringFromTable(@"create_room", @"MatrixConsole", nil);
    }
    else if (section == joinRoomSection)
    {
        sectionLabel.text = NSLocalizedStringFromTable(@"join_room", @"MatrixConsole", nil);
    }
    else
    {
        NSArray *publicRooms = nil;
        NSString *homeserver;
        NSInteger index = section - publicRoomsFirstSection;
        if (index < homeServers.count)
        {
            homeserver = [homeServers objectAtIndex:index];
            
            if (filteredPublicRoomsDict)
            {
                publicRooms = [filteredPublicRoomsDict objectForKey:homeserver];
            }
            else
            {
                publicRooms = [publicRoomsDict objectForKey:homeserver];
            }
        }
        
        if (publicRooms)
        {
            sectionLabel.text = [NSString stringWithFormat:NSLocalizedStringFromTable(@"public_room_section_title", @"MatrixConsole", nil), homeserver];
            
            if (homeServers.count > 1)
            {
                // Add shrink button
                UIButton *shrinkButton = [UIButton buttonWithType:UIButtonTypeCustom];
                CGRect frame = sectionHeader.frame;
                frame.origin.x = frame.origin.y = 0;
                shrinkButton.frame = frame;
                shrinkButton.backgroundColor = [UIColor clearColor];
                [shrinkButton addTarget:self action:@selector(onButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
                shrinkButton.tag = index;
                [sectionHeader addSubview:shrinkButton];
                sectionHeader.userInteractionEnabled = YES;
                
                // Add shrink icon
                UIImage *chevron;
                if ([shrinkedHomeServers indexOfObject:homeserver] != NSNotFound)
                {
                    chevron = [NSBundle mxk_imageFromMXKAssetsBundleWithName:@"disclosure"];
                }
                else
                {
                    chevron =[NSBundle mxk_imageFromMXKAssetsBundleWithName:@"shrink"];
                }
                UIImageView *chevronView = [[UIImageView alloc] initWithImage:chevron];
                chevronView.contentMode = UIViewContentModeCenter;
                frame = chevronView.frame;
                frame.origin.x = sectionHeader.frame.size.width - frame.size.width - 8;
                frame.origin.y = (sectionHeader.frame.size.height - frame.size.height) / 2;
                chevronView.frame = frame;
                [sectionHeader addSubview:chevronView];
                chevronView.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin);
                
                // Update label frame
                frame = sectionHeader.frame;
                frame.origin.x = 5;
                frame.origin.y = 5;
                frame.size.width = chevronView.frame.origin.x - 10;
                frame.size.height -= 10;
                sectionLabel.frame = frame;
            }
        }
        else
        {
            sectionLabel.text = [NSString stringWithFormat:NSLocalizedStringFromTable(@"public_room_empty_section_title", @"MatrixConsole", nil), homeserver];
        }
    }
    
    return sectionHeader;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section < publicRoomsFirstSection)
    {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
    }
    else
    {
        // Here the user has selected a public room.
        // Prompt user to select an account in case of multi-sessions before opening this room
        [[AppDelegate theDelegate] selectMatrixAccount:^(MXKAccount *selectedAccount)
        {
            // Retrieve the selected public room.
            MXPublicRoom *publicRoom;
            
            // CAUTION: The public room must be retrieved before dismissing the keyboard, because the table view may be reloaded when keyboard is dismissed.
            NSInteger homeServerIndex = indexPath.section - publicRoomsFirstSection;
            if (homeServerIndex < homeServers.count)
            {
                NSString *homeserver = [homeServers objectAtIndex:homeServerIndex];
                NSArray *publicRooms = nil;
                if (filteredPublicRoomsDict)
                {
                    publicRooms = [filteredPublicRoomsDict objectForKey:homeserver];
                }
                else
                {
                    publicRooms = [publicRoomsDict objectForKey:homeserver];
                }
                
                if (indexPath.row < publicRooms.count)
                {
                    publicRoom = [publicRooms objectAtIndex:indexPath.row];
                }
            }
            
            // Hide the keyboard when user selects a room
            [self dismissKeyboard];
            
            if (publicRoom)
            {
                // Check whether the user has already joined the selected public room
                if ([selectedAccount.mxSession roomWithRoomId:publicRoom.roomId])
                {
                    // Open selected room
                    [[AppDelegate theDelegate].masterTabBarController showRoom:publicRoom.roomId withMatrixSession:selectedAccount.mxSession];
                }
                else
                {
                    // Join the selected room
                    UIActivityIndicatorView *loadingWheel = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
                    UITableViewCell *selectedCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (selectedCell)
                    {
                        CGPoint center = CGPointMake(selectedCell.frame.size.width / 2, selectedCell.frame.size.height / 2);
                        loadingWheel.center = center;
                        [selectedCell addSubview:loadingWheel];
                    }
                    [loadingWheel startAnimating];
                    [selectedAccount.mxSession joinRoom:publicRoom.roomId success:^(MXRoom *room)
                    {
                        // Show joined room
                        [loadingWheel stopAnimating];
                        [loadingWheel removeFromSuperview];
                        [[AppDelegate theDelegate].masterTabBarController showRoom:publicRoom.roomId withMatrixSession:selectedAccount.mxSession];
                    } failure:^(NSError *error)
                    {
                        NSLog(@"[HomeVC] Failed to join public room (%@): %@", publicRoom.displayname, error);
                        //Alert user
                        [loadingWheel stopAnimating];
                        [loadingWheel removeFromSuperview];
                        [[AppDelegate theDelegate] showErrorAsAlert:error];
                    }];
                }
                
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
            }
        }];
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    // Update filtered list
    if (searchText.length)
    {
        if (filteredPublicRoomsDict)
        {
            [filteredPublicRoomsDict removeAllObjects];
        }
        else
        {
            filteredPublicRoomsDict = [NSMutableDictionary dictionaryWithCapacity:homeServers.count];
        }
        
        for (NSString *homeserver in homeServers)
        {
            NSArray *publicRooms = [publicRoomsDict objectForKey:homeserver];
            
            NSMutableArray *filteredRooms = [NSMutableArray array];
            for (MXPublicRoom *publicRoom in publicRooms)
            {
                if ([[publicRoom displayname] rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound)
                {
                    [filteredRooms addObject:publicRoom];
                }
            }
            
            if (filteredRooms.count)
            {
                [filteredPublicRoomsDict setObject:filteredRooms forKey:homeserver];
            }
        }
    }
    else
    {
        filteredPublicRoomsDict = nil;
    }
    // Refresh display
    [self.tableView reloadData];
    if (filteredPublicRoomsDict.count)
    {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    // "Done" key has been pressed
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    // Leave search
    [searchBar resignFirstResponder];
    
    _publicRoomsSearchBar.hidden = YES;
    _publicRoomsSearchBarHeightConstraint.constant = 0;
    [self.view setNeedsUpdateConstraints];
    
    _publicRoomsSearchBar.text = nil;
    
    filteredPublicRoomsDict = nil;
    [self.tableView reloadData];
    if (self.tableView.numberOfSections && [self tableView:self.tableView numberOfRowsInSection:0])
    {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    }
}

@end
