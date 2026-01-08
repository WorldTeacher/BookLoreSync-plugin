import {beforeEach, describe, expect, it, vi} from 'vitest';
import {TestBed} from '@angular/core/testing';
import {BehaviorSubject, of, throwError} from 'rxjs';
import {MessageService} from 'primeng/api';
import {NO_ERRORS_SCHEMA} from '@angular/core';
import {HardcoverSettingsComponent} from './hardcover-settings-component';
import {HardcoverSyncSettingsService} from './hardcover-sync-settings.service';
import {UserService, UserState} from '../../../user-management/user.service';

describe('HardcoverSettingsComponent', () => {
  let settingsServiceMock: any;
  let messageServiceMock: any;
  let userState$: BehaviorSubject<UserState>;

  const makeState = (permissions: Partial<UserState['user']> = {}): UserState => ({
    loaded: true,
    error: null,
    user: {
      id: 1,
      username: 'u',
      name: 'User',
      email: 'u@example.com',
      assignedLibraries: [],
      provisioningMethod: 'LOCAL',
      permissions: {
        admin: false,
        canUpload: false,
        canDownload: false,
        canEmailBook: false,
        canDeleteBook: false,
        canEditMetadata: false,
        canManageLibrary: false,
        canManageMetadataConfig: false,
        canSyncKoReader: false,
        canSyncKobo: false,
        canAccessOpds: false,
        canAccessBookdrop: false,
        canAccessLibraryStats: false,
        canAccessUserStats: false,
        canAccessTaskManager: false,
        canManageEmailConfig: false,
        canManageGlobalPreferences: false,
        canManageIcons: false,
        demoUser: false,
        canBulkAutoFetchMetadata: false,
        canBulkCustomFetchMetadata: false,
        canBulkEditMetadata: false,
        canBulkRegenerateCover: false,
        canMoveOrganizeFiles: false,
        canBulkLockUnlockMetadata: false
      },
      userSettings: {} as any,
      ...permissions
    }
  });

  beforeEach(() => {
    settingsServiceMock = {
      getSettings: vi.fn(),
      updateSettings: vi.fn()
    };
    messageServiceMock = {
      add: vi.fn()
    };
    userState$ = new BehaviorSubject<UserState>(makeState());

    TestBed.configureTestingModule({
      imports: [HardcoverSettingsComponent],
      providers: [
        {provide: HardcoverSyncSettingsService, useValue: settingsServiceMock},
        {provide: MessageService, useValue: messageServiceMock},
        {provide: UserService, useValue: {userState$: userState$}}
      ],
      schemas: [NO_ERRORS_SCHEMA]
    });
  });

  it('should load settings when user has permission', async () => {
    settingsServiceMock.getSettings.mockReturnValue(of({hardcoverSyncEnabled: true, hardcoverApiKey: 'key'}));
    userState$.next(makeState({
      permissions: {
        ...makeState().user!.permissions,
        canSyncKobo: true
      }
    }) as UserState);

    const fixture = TestBed.createComponent(HardcoverSettingsComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();
    await fixture.whenStable();

    expect(settingsServiceMock.getSettings).toHaveBeenCalled();
    expect(component.hardcoverSyncEnabled).toBe(true);
    expect(component.hardcoverApiKey).toBe('key');
  });

  it('should not load settings without permission', async () => {
    settingsServiceMock.getSettings.mockReturnValue(of({}));
    userState$.next(makeState());
    const fixture = TestBed.createComponent(HardcoverSettingsComponent);
    fixture.detectChanges();
    await fixture.whenStable();
    expect(settingsServiceMock.getSettings).not.toHaveBeenCalled();
  });

  it('should update settings on toggle', async () => {
    settingsServiceMock.updateSettings.mockReturnValue(of({hardcoverSyncEnabled: false, hardcoverApiKey: 'k'}));
    const fixture = TestBed.createComponent(HardcoverSettingsComponent);
    const component = fixture.componentInstance;
    component.hardcoverSyncEnabled = false;
    component.hardcoverApiKey = 'k';

    component.onHardcoverSyncToggle();
    await fixture.whenStable();

    expect(settingsServiceMock.updateSettings).toHaveBeenCalledWith({
      hardcoverSyncEnabled: false,
      hardcoverApiKey: 'k'
    });
  });

  it('should handle update error', async () => {
    settingsServiceMock.updateSettings.mockReturnValue(throwError(() => new Error('fail')));
    const fixture = TestBed.createComponent(HardcoverSettingsComponent);
    const component = fixture.componentInstance;
    component.hardcoverSyncEnabled = true;
    component.hardcoverApiKey = 'k';

    component.onHardcoverApiKeyChange();
    await fixture.whenStable();

    expect(settingsServiceMock.updateSettings).toHaveBeenCalled();
  });

  it('should handle load error', async () => {
    settingsServiceMock.getSettings.mockReturnValue(throwError(() => new Error('fail')));
    userState$.next(makeState({
      permissions: {
        ...makeState().user!.permissions,
        admin: true
      }
    }) as UserState);

    const fixture = TestBed.createComponent(HardcoverSettingsComponent);
    fixture.detectChanges();
    await fixture.whenStable();

    expect(settingsServiceMock.getSettings).toHaveBeenCalled();
  });
});
