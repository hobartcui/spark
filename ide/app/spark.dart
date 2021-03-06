// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark;

import 'dart:async';
import 'dart:convert' show JSON;
import 'dart:html' hide File;

import 'package:chrome/chrome_app.dart' as chrome;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

// BUG(ussuri): https://github.com/dart-lang/spark/issues/500
import 'packages/spark_widgets/spark_status/spark_status.dart';

import 'lib/ace.dart';
import 'lib/actions.dart';
import 'lib/analytics.dart' as analytics;
import 'lib/app.dart';
import 'lib/apps/app_utils.dart';
import 'lib/builder.dart';
import 'lib/dart/dart_builder.dart';
import 'lib/editors.dart';
import 'lib/editor_area.dart';
import 'lib/event_bus.dart';
import 'lib/json/json_builder.dart';
import 'lib/jobs.dart';
import 'lib/launch.dart';
import 'lib/mobile/deploy.dart';
import 'lib/package_mgmt/pub.dart';
import 'lib/package_mgmt/bower.dart';
import 'lib/preferences.dart' as preferences;
import 'lib/services.dart';
import 'lib/scm.dart';
import 'lib/templates.dart';
import 'lib/tests.dart';
import 'lib/utils.dart';
import 'lib/ui/files_controller.dart';
import 'lib/ui/polymer/commit_message_view/commit_message_view.dart';
import 'lib/ui/widgets/splitview.dart';
import 'lib/utils.dart' as utils;
import 'lib/webstore_client.dart';
import 'lib/workspace.dart' as ws;
import 'lib/workspace_utils.dart' as ws_utils;
import 'test/all.dart' as all_tests;

import 'spark_model.dart';

analytics.Tracker _analyticsTracker = new analytics.NullTracker();
final NumberFormat _nf = new NumberFormat.decimalPattern();

/**
 * Returns true if app.json contains a test-mode entry set to true. If app.json
 * does not exit, it returns true.
 */
Future<bool> isTestMode() {
  final String url = chrome.runtime.getURL('app.json');
  return HttpRequest.getString(url).then((String contents) {
    bool result = true;
    try {
      Map info = JSON.decode(contents);
      result = info['test-mode'];
    } catch (exception, stackTrace) {
      // If JSON is invalid, assume test mode.
      result = true;
    }
    return result;
  }).catchError((e) {
    return true;
  });
}

/**
 * Create a [Zone] that logs uncaught exceptions.
 */
Zone createSparkZone() {
  var errorHandler = (self, parent, zone, error, stackTrace) {
    _handleUncaughtException(error, stackTrace);
  };
  var specification = new ZoneSpecification(handleUncaughtError: errorHandler);
  return Zone.current.fork(specification: specification);
}

abstract class Spark
    extends SparkModel
    implements AceManagerDelegate, Notifier {

  /// The Google Analytics app ID for Spark.
  static final _ANALYTICS_ID = 'UA-45578231-1';

  final bool developerMode;

  Services services;
  final JobManager jobManager = new JobManager();
  SparkStatus statusComponent;

  AceManager _aceManager;
  ThemeManager _aceThemeManager;
  KeyBindingManager _aceKeysManager;
  ws.Workspace _workspace;
  ScmManager scmManager;
  EditorManager _editorManager;
  EditorArea _editorArea;
  LaunchManager _launchManager;
  PubManager _pubManager;
  BowerManager _bowerManager;
  ActionManager _actionManager;
  ProjectLocationManager projectLocationManager;

  EventBus _eventBus;

  SplitView _splitView;

  FilesController _filesController;

  PlatformInfo _platformInfo;

  TestDriver _testDriver;

  // Extensions of files that will be shown as text.
  Set<String> _textFileExtensions = new Set.from(
      ['.cmake', '.gitignore', '.prefs', '.txt']);

  Spark(this.developerMode) {
    document.title = appName;

    initEventBus();

    initAnalytics();

    addParticipant(new _SparkSetupParticipant(this));

    initWorkspace();
    initPackageManagers();
    initServices();
    initScmManager();

    createEditorComponents();
    initEditorArea();
    initEditorManager();

    createActions();

    initFilesController();

    initToolbar();
    buildMenu();

    initSplitView();
    initSaveStatusListener();

    initLaunchManager();

    window.onFocus.listen((Event e) {
      // When the user switch to an other application, he might change the
      // content of the workspace from other applications. For that reason, when
      // the user switch back to Spark, we want to check whether the content of
      // the workspace changed.

      // TODO(dvh): Disabled because of performance issue. Still need some
      // tweaking before enabling it by default.
      //workspace.refresh();
    });

    // Add various builders.
    addBuilder(new DartBuilder(this.services));
    addBuilder(new JsonBuilder());
  }

  initServices() {
    services = new Services(this.workspace, _pubManager);
  }

  //
  // SparkModel interface:
  //

  AceManager get aceManager => _aceManager;
  ThemeManager get aceThemeManager => _aceThemeManager;
  KeyBindingManager get aceKeysManager => _aceKeysManager;
  ws.Workspace get workspace => _workspace;
  EditorManager get editorManager => _editorManager;
  EditorArea get editorArea => _editorArea;
  LaunchManager get launchManager => _launchManager;
  PubManager get pubManager => _pubManager;
  BowerManager get bowerManager => _bowerManager;
  ActionManager get actionManager => _actionManager;

  EventBus get eventBus => _eventBus;

  preferences.PreferenceStore get localPrefs => preferences.localStore;
  preferences.PreferenceStore get syncPrefs => preferences.syncStore;

  //
  // - End SparkModel interface.
  //

  String get appName => utils.i18n('app_name');

  String get appVersion => chrome.runtime.getManifest()['version'];

  PlatformInfo get platformInfo => _platformInfo;

  /**
   * Get the currently selected [Resource].
   */
  ws.Resource get currentResource => focusManager.currentResource;

  /**
   * Get the [File] currently being edited.
   */
  ws.File get currentEditedFile => focusManager.currentEditedFile;

  /**
   * Get the currently selected [Project].
   */
  ws.Project get currentProject => focusManager.currentProject;

  // TODO(ussuri): The below two methods are a temporary means to make Spark
  // reusable in SparkPolymer. Once the switch to Polymer is complete, they
  // will go away.

  /**
   * Should extract a UI Element from the underlying DOM. This method
   * is overwritten in SparkPolymer, which encapsulates the UI in a top-level
   * Polymer widget, rather than the top-level document's DOM.
   */
  Element getUIElement(String selectors) =>
      document.querySelector(selectors);

  /**
   * Should extract a dialog Element from the underlying UI's DOM. This is
   * different from [getUIElement] in that it's not currently overridden in
   * SparkPolymer.
   */
  Element getDialogElement(String selectors) =>
      document.querySelector(selectors);

  SparkDialog createDialog(Element dialogElement);

  //
  // Parts of ctor:
  //

  void initEventBus() {
    _eventBus = new EventBus();
    _eventBus.onEvent(BusEventType.ERROR_MESSAGE).listen(
        (ErrorMessageBusEvent event) {
      showErrorMessage(event.title, event.error.toString());
    });
  }

  void initAnalytics() {
    // Init the analytics tracker and send a page view for the main page.
    analytics.getService('Spark').then((service) {
      _analyticsTracker = service.getTracker(_ANALYTICS_ID);
      _analyticsTracker.sendAppView('main');
    });

    // Track logged exceptions.
    Logger.root.onRecord.listen((LogRecord r) {
      if (!developerMode && r.level <= Level.INFO) return;

      print(r.toString() + (r.error != null ? ', ${r.error}' : ''));

      if (r.level >= Level.SEVERE) {
        _handleUncaughtException(r.error, r.stackTrace);
      }
    });
  }

  void initWorkspace() {
    _workspace = new ws.Workspace(localPrefs, jobManager);
  }

  void initScmManager() {
    scmManager = new ScmManager(_workspace);
  }

  void initLaunchManager() {
    _launchManager = new LaunchManager(_workspace, services, pubManager);
  }

  void initPackageManagers() {
    _pubManager = new PubManager(workspace);
    _bowerManager = new BowerManager(workspace);
  }

  void createEditorComponents() {
    _aceManager = new AceManager(new DivElement(), this, services);
    _aceThemeManager = new ThemeManager(
        aceManager, syncPrefs, getUIElement('#changeTheme .settings-label'));
    _aceKeysManager = new KeyBindingManager(
        aceManager, syncPrefs, getUIElement('#changeKeys .settings-label'));
    _editorManager = new EditorManager(
        workspace, aceManager, localPrefs, eventBus, services);
    _editorArea = new EditorArea(querySelector('#editorArea'), editorManager,
        _workspace, allowsLabelBar: true);

    syncPrefs.getValue('textFileExtensions').then((String value) {
      if (value != null) {
        _textFileExtensions.addAll(JSON.decode(value));
      }
    });
  }

  void initEditorManager() {
    editorManager.loaded.then((_) {
      List<ws.Resource> files = editorManager.files.toList();
      editorManager.files.forEach((file) {
        editorArea.selectFile(file, forceOpen: true, switchesTab: false);
      });
      localPrefs.getValue('lastFileSelection').then((String fileUuid) {
        if (editorArea.tabs.isEmpty) return;
        if (fileUuid == null) {
          editorArea.tabs[0].select();
          return;
        }
        ws.Resource resource = workspace.restoreResource(fileUuid);
        if (resource == null) {
          editorArea.tabs[0].select();
          return;
        }
        _selectResource(resource);
      });
    });
  }

  void initEditorArea() {
    editorArea.onSelected.listen((EditorTab tab) {
      // We don't change the selection when the file was already selected
      // otherwise, it would break multi-selection (#260).
      if (!_filesController.isFileSelected(tab.file)) {
        _filesController.selectFile(tab.file);
      }
      localPrefs.setValue('lastFileSelection', tab.file.uuid);
      focusManager.setEditedFile(tab.file);
    });
  }

  void initFilesController() {
    _filesController = new FilesController(
        workspace, actionManager, scmManager, eventBus,
        querySelector('#file-item-context-menu'),
        querySelector('#fileViewArea'));
    eventBus.onEvent(BusEventType.FILES_CONTROLLER__SELECTION_CHANGED)
        .listen((FilesControllerSelectionChangedEvent event) {
      focusManager.setCurrentResource(event.resource);
      if (event.resource is ws.File) {
        _selectInEditor(
            event.resource,
            forceOpen: event.forceOpen,
            replaceCurrent: event.replaceCurrent,
            switchesTab: event.switchesTab);
      }
    });
  }

  void initSplitView() {
    _splitView = new SplitView(getUIElement('#splitview'));
    _splitView.onResized.listen((_) {
      aceManager.resize();
      syncPrefs.setValue('splitViewPosition', _splitView.position.toString());
    });
    syncPrefs.getValue('splitViewPosition').then((String position) {
      if (position != null) {
        int value = int.parse(position, onError: (_) => 0);
        if (value != 0) {
          _splitView.position = value;
        }
      }
    });
  }

  void initSaveStatusListener() {
    // Overridden in spark_polymer.dart.
  }

  void createActions() {
    _actionManager = new ActionManager();

    actionManager.registerAction(new NextMarkerAction(this));
    actionManager.registerAction(new PrevMarkerAction(this));
    actionManager.registerAction(new FileOpenAction(this));
    actionManager.registerAction(new FileNewAction(this, getDialogElement('#fileNewDialog')));
    actionManager.registerAction(new FolderNewAction(this, getDialogElement('#folderNewDialog')));
    actionManager.registerAction(new FolderOpenAction(this));
    actionManager.registerAction(new NewProjectAction(this, getDialogElement('#newProjectDialog')));
    actionManager.registerAction(new FileOpenInTabAction(this));
    actionManager.registerAction(new FileSaveAction(this));
    actionManager.registerAction(new PubGetAction(this));
    actionManager.registerAction(new PubUpgradeAction(this));
    actionManager.registerAction(new BowerGetAction(this));
    actionManager.registerAction(new ApplicationRunAction(this));
    actionManager.registerAction(new ApplicationPushAction(this, getDialogElement('#pushDialog')));
    actionManager.registerAction(new CompileDartAction(this));
    actionManager.registerAction(new GitCloneAction(this, getDialogElement("#gitCloneDialog")));
    actionManager.registerAction(new GitPullAction(this));
    actionManager.registerAction(new GitBranchAction(this, getDialogElement("#gitBranchDialog")));
    actionManager.registerAction(new GitCheckoutAction(this, getDialogElement("#gitCheckoutDialog")));
    actionManager.registerAction(new GitResolveConflictsAction(this));
    actionManager.registerAction(new GitCommitAction(this, getDialogElement("#gitCommitDialog")));
    actionManager.registerAction(new GitRevertChangesAction(this));
    actionManager.registerAction(new GitPushAction(this, getDialogElement("#gitPushDialog")));
    actionManager.registerAction(new RunTestsAction(this));
    actionManager.registerAction(new SettingsAction(this, getDialogElement('#settingsDialog')));
    actionManager.registerAction(new AboutSparkAction(this, getDialogElement('#aboutDialog')));
    actionManager.registerAction(new FileRenameAction(this, getDialogElement('#renameDialog')));
    actionManager.registerAction(new ResourceRefreshAction(this));
    // The top-level 'Close' action is removed for now: #1037.
    //actionManager.registerAction(new ResourceCloseAction(this));
    actionManager.registerAction(new TabCloseAction(this));
    actionManager.registerAction(new TabPreviousAction(this));
    actionManager.registerAction(new TabNextAction(this));
    actionManager.registerAction(new SpecificTabAction(this));
    actionManager.registerAction(new TabLastAction(this));
    actionManager.registerAction(new FileExitAction(this));
    actionManager.registerAction(new WebStorePublishAction(this, getDialogElement('#webStorePublishDialog')));
    actionManager.registerAction(new SearchAction(this));
    actionManager.registerAction(new FormatAction(this));
    actionManager.registerAction(new FocusMainMenuAction(this));
    actionManager.registerAction(new ImportFileAction(this));
    actionManager.registerAction(new ImportFolderAction(this));
    actionManager.registerAction(new FileDeleteAction(this));
    actionManager.registerAction(new PropertiesAction(this, getDialogElement("#propertiesDialog")));

    actionManager.registerKeyListener();
  }

  void initToolbar() {
  }

  void buildMenu() {
  }

  //
  // - End parts of ctor.
  //

  void addBuilder(Builder builder) {
    workspace.builderManager.builders.add(builder);
  }

  Future openFile() {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.OPEN_WRITABLE_FILE);
    return chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
      chrome.ChromeFileEntry entry = res.entry;

      if (entry != null) {
        workspace.link(new ws.FileRoot(entry)).then((ws.Resource file) {
          _selectResource(file);
          _aceManager.focus();
          workspace.save();
        });
      }
    });
  }

  Future openFolder() {
    return _selectFolder().then((chrome.DirectoryEntry entry) {
      if (entry != null) {
        _OpenFolderJob job = new _OpenFolderJob(entry, this);
        jobManager.schedule(job);
      }
    });
  }

  void showSuccessMessage(String message) {
    statusComponent.temporaryMessage = message;
  }

  SparkDialog _errorDialog;

  void showMessage(String title, String message) {
    showErrorMessage(title, message);
  }

    // Implemented in a sub-class.
  void unveil() { }

  /**
   * Show a model error dialog.
   */
  void showErrorMessage(String title, String message) {
    if (_errorDialog == null) {
      _errorDialog = createDialog(getDialogElement('#errorDialog'));
      _errorDialog.element.querySelector("[primary]").onClick.listen(_hideBackdropOnClick);
    }

    _errorDialog.element.querySelector('#errorTitle').text = title;
    Element container = _errorDialog.element.querySelector('#errorMessage');
    container.children.clear();
    var lines = message.split('\n');
    for(String line in lines) {
      Element lineElement = new Element.p();
      lineElement.text = line;
      container.children.add(lineElement);
    }

    _errorDialog.show();
  }

  SparkDialog _progressDialog;

  void showProgressDialog(String selector) {
    _progressDialog = createDialog(getDialogElement('${selector}'));
    _progressDialog.show();
  }

  void hideProgressDialog() {
    _progressDialog.hide();
    _progressDialog = null;
  }

  void _hideBackdropOnClick(MouseEvent event) {
    querySelector("#modalBackdrop").style.display = "none";
  }

  SparkDialog _publishedAppDialog;

  void showPublishedAppDialog(String appID) {
    if (_publishedAppDialog == null) {
      _publishedAppDialog = createDialog(getDialogElement('#webStorePublishedDialog'));
      _publishedAppDialog.element.querySelector("[primary]").onClick.listen(_hideBackdropOnClick);
      _publishedAppDialog.element.querySelector("#webStorePublishedAction").onClick.listen((MouseEvent event) {
        window.open('https://chrome.google.com/webstore/detail/${appID}',
            '_blank');
        _hideBackdropOnClick(event);
      });
    }
    _publishedAppDialog.show();
  }

  SparkDialog _uploadedAppDialog;

  void showUploadedAppDialog(String appID) {
    if (_uploadedAppDialog == null) {
      _uploadedAppDialog = createDialog(getDialogElement('#webStoreUploadedDialog'));
      _uploadedAppDialog.element.querySelector("[primary]").onClick.listen(_hideBackdropOnClick);
      _uploadedAppDialog.element.querySelector("#webStoreUploadedAction").onClick.listen((MouseEvent event) {
        window.open('https://chrome.google.com/webstore/developer/edit/${appID}',
            '_blank');
        _hideBackdropOnClick(event);
      });
    }
    _uploadedAppDialog.show();
  }

  SparkDialog _okCancelDialog;
  Completer<bool> _okCancelCompleter;

  Future<bool> askUserOkCancel(String message, {String okButtonLabel: 'OK'}) {
    if (_okCancelDialog == null) {
      _okCancelDialog = createDialog(getDialogElement('#okCancelDialog'));
      _okCancelDialog.element.querySelector('#okText').onClick.listen((_) {
        if (_okCancelCompleter != null) {
          _okCancelCompleter.complete(true);
          _okCancelCompleter = null;
        }
      });
      _okCancelDialog.element.on['opened'].listen((event) {
        if (event.detail == false) {
          if (_okCancelCompleter != null) {
            _okCancelCompleter.complete(false);
            _okCancelCompleter = null;
          }
        }
      });
    }

    _okCancelDialog.element.querySelector('#okCancelMessage').text = message;
    _okCancelDialog.element.querySelector('#okText').text = okButtonLabel;

    _okCancelCompleter = new Completer();
    _okCancelDialog.show();
    return _okCancelCompleter.future;
  }

  void onSplitViewUpdate(int position) { }

  void setGitSettingsResetDoneVisible(bool enabled) {
    getUIElement('#gitResetSettingsDone').hidden = !enabled;
  }

  List<ws.Resource> _getSelection() => _filesController.getSelection();

  ws.Folder _getFolder([List<ws.Resource> resources]) {
    if (resources != null && resources.isNotEmpty) {
      if (resources.first.isFile) {
        return resources.first.parent;
      } else {
        return resources.first;
      }
    } else {
      if (focusManager.currentResource != null) {
        ws.Resource resource = focusManager.currentResource;
        if (resource.isFile) {
          if (resource.project != null) {
            return resource.parent;
          }
        } else {
          return resource;
        }
      }
    }
    return null;
  }

  void _closeOpenEditor(ws.Resource resource) {
    if (resource is ws.File &&  editorManager.isFileOpened(resource)) {
      editorArea.closeFile(resource);
    }
  }

  /**
   * Refreshes the file name on an opened editor tab.
   */
  void _renameOpenEditor(ws.Resource renamedResource) {
    if (renamedResource is ws.File && editorManager.isFileOpened(renamedResource)) {
      editorArea.renameFile(renamedResource);
    }
  }

  void _selectResource(ws.Resource resource) {
    if (resource.isFile) {
      editorArea.selectFile(
          resource, forceOpen: true, switchesTab: true, forceFocus: true);
    } else {
      _filesController.selectFile(resource);
      _filesController.setFolderExpanded(resource);
    }
  }

  void _selectInEditor(ws.File file,
                       {bool forceOpen: false,
                        bool replaceCurrent: true,
                        bool switchesTab: true}) {
    if (forceOpen || editorManager.isFileOpened(file)) {
      editorArea.selectFile(file,
          forceOpen: forceOpen,
          replaceCurrent: replaceCurrent,
          switchesTab: switchesTab);
    }
  }

  //
  // Implementation of AceManagerDelegate interface:
  //

  void setShowFileAsText(String filename, bool enabled) {
    String extension = path.extension(filename);
    if (extension.isEmpty) extension = filename;

    if (enabled) {
      _textFileExtensions.add(extension);
    } else {
      _textFileExtensions.remove(extension);
    }

    syncPrefs.setValue('textFileExtensions',
        JSON.encode(_textFileExtensions.toList()));
  }

  bool canShowFileAsText(String filename) {
    String extension = path.extension(filename);

    // Whitelist files that don't have a period or that start with one. Ex.,
    // `AUTHORS`, `.gitignore`.
    if (extension.isEmpty) return true;

    return _aceManager.isFileExtensionEditable(extension) ||
        _textFileExtensions.contains(extension);
  }
  //
  // - End implementation of AceManagerDelegate interface.
  //
}

class PlatformInfo {
  /**
   * The operating system chrome is running on. One of: "mac", "win", "android",
   * "cros", "linux", "openbsd".
   */
  final String os;

  /**
   * The machine's processor architecture. One of: "arm", "x86-32", "x86-64".
   */
  final String arch;

  /**
   * The native client architecture. This may be different from arch on some
   * platforms. One of: "arm", "x86-32", "x86-64".
   */
  final String naclArch;

  PlatformInfo._(this.os, this.arch, this.naclArch);

  PlatformInfo.fromMap(Map m) : this._(m['os'], m['arch'], m['nacl_arch']);

  String toString() => "${os}, ${arch}, ${naclArch}";

  bool get isCros => os == 'cros';
}

/**
 * Used to manage the default location to create new projects.
 *
 * This class also abstracts a bit other the differences between Chrome OS and
 * Windows/Mac/linux.
 */
class ProjectLocationManager {
  preferences.PreferenceStore _prefs;
  LocationResult _projectLocation;
  final ws.Workspace _workspace;

  /**
   * Create a ProjectLocationManager asynchronously, restoring the default
   * project location from the given preferences.
   */
  static Future<ProjectLocationManager> restoreManager(
      preferences.PreferenceStore prefs, ws.Workspace workspace) {
    return prefs.getValue('projectFolder').then((String folderToken) {
      if (folderToken == null) {
        return new ProjectLocationManager._(prefs, workspace);
      }

      return chrome.fileSystem.restoreEntry(folderToken).then((chrome.Entry entry) {
        return new ProjectLocationManager._(prefs, workspace,
            new LocationResult(entry, entry, false));
      }).catchError((e) {
        return new ProjectLocationManager._(prefs, workspace);
      });
    });
  }

  ProjectLocationManager._(this._prefs, this._workspace, [this._projectLocation]);

  /**
   * Returns the default location to create new projects in. For Chrome OS, this
   * will be the sync filesystem. This method can return `null` if the user
   * cancels the folder selection dialog.
   */
  Future<LocationResult> getProjectLocation() {
    if (_projectLocation != null) {
      // Check if the saved location exists. If so, return it. Otherwise, get a
      // new location.
      return _projectLocation.exists().then((bool value) {
        if (value) {
          return _projectLocation;
        } else {
          _projectLocation = null;
          return getProjectLocation();
        }
      });
    }

    // On Chrome OS, use the sync filesystem.
    if (_isCros() && _workspace.syncFsIsAvailable) {
      return chrome.syncFileSystem.requestFileSystem().then((fs) {
        var entry = fs.root;
        return new LocationResult(entry, entry, true);
      });
    }

    // Display a dialog asking the user to choose a default project folder.
    // TODO: We need to provide an explaination to the user about what this
    // folder is for.
    return _selectFolder(suggestedName: 'projects').then((entry) {
      if (entry == null) {
        return null;
      }

      _projectLocation = new LocationResult(entry, entry, false);
      _prefs.setValue('projectFolder', chrome.fileSystem.retainEntry(entry));
      return _projectLocation;
    });
  }

  /**
   * This will create a new folder in default project location. It will attempt
   * to use the given [defaultName], but will disambiguate it if necessary. For
   * example, if `defaultName` already exists, the created folder might be named
   * something like `defaultName-1` instead.
   */
  Future<LocationResult> createNewFolder(String defaultName) {
    return getProjectLocation().then((LocationResult root) {
      return root == null ? null : _create(root, defaultName, 1);
    });
  }

  Future<LocationResult> _create(
      LocationResult location, String baseName, int count) {
    String name = count == 1 ? baseName : '${baseName}-${count}';

    return location.parent.createDirectory(name, exclusive: true).then((dir) {
      return new LocationResult(location.parent, dir, location.isSync);
    }).catchError((_) {
      if (count > 50) {
        throw "Error creating project '${baseName}.'";
      } else {
        return _create(location, baseName, count + 1);
      }
    });
  }
}

class LocationResult {
  /**
   * The parent Entry. This can be useful for persistng the info across
   * sessions.
   */
  final chrome.DirectoryEntry parent;

  /**
   * The created location.
   */
  final chrome.DirectoryEntry entry;

  /**
   * Whether the entry was created in the sync filesystem.
   */
  final bool isSync;

  LocationResult(this.parent, this.entry, this.isSync);

  /**
   * The name of the created entry.
   */
  String get name => entry.name;

  Future<bool> exists() {
    if (isSync) return new Future.value(true);

    return entry.getMetadata().then((_) {
      return true;
    }).catchError((e) {
      return false;
    });
  }
}

class _SparkSetupParticipant extends LifecycleParticipant {
  Spark spark;

  _SparkSetupParticipant(this.spark);

  Future applicationStarting(Application application) {
    // get platform info
    return chrome.runtime.getPlatformInfo().then((Map m) {
      spark._platformInfo = new PlatformInfo.fromMap(m);
      return spark.workspace.restore().then((value) {
        if (spark.workspace.getFiles().length == 0) {
          // No files, just focus the editor.
          spark.aceManager.focus();
        }
      });
    }).then((_) {
      return ProjectLocationManager.restoreManager(spark.localPrefs,
          spark.workspace).then((manager) {
        spark.projectLocationManager = manager;
      });
    }).whenComplete(() => spark.unveil());
  }

  Future applicationStarted(Application application) {
    if (spark.developerMode) {
      spark._testDriver = new TestDriver(
          all_tests.defineTests, spark.jobManager, connectToTestListener: true);
    }
    return new Future.value();
  }

  Future applicationClosed(Application application) {
    spark.editorManager.persistState();
    spark.launchManager.dispose();
    spark.localPrefs.flush();
    spark.syncPrefs.flush();
    return new Future.value();
  }
}

/**
 * Allows a user to select a folder on disk. Returns the selected folder
 * entry. Returns `null` in case the user cancels the action.
 */
Future<chrome.DirectoryEntry> _selectFolder({String suggestedName}) {
  Completer completer = new Completer();
  chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
      type: chrome.ChooseEntryType.OPEN_DIRECTORY);
  if (suggestedName != null) options.suggestedName = suggestedName;
  chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
    completer.complete(res.entry);
  }).catchError((e) => completer.complete(null));
  return completer.future;
}

bool _isCros() {
  return (SparkModel.instance as Spark).platformInfo.isCros;
}

/**
 * The abstract parent class of Spark related actions.
 */
abstract class SparkAction extends Action {
  Spark spark;

  SparkAction(this.spark, String id, String name) : super(id, name);

  void invoke([Object context]) {
    // Send an action event with the 'main' event category.
    _analyticsTracker.sendEvent('main', id);

    _invoke(context);
  }

  void _invoke([Object context]);

  /**
   * Returns true if `object` is a list and all items are [Resource].
   */
  bool _isResourceList(Object object) {
    if (object is! List) {
      return false;
    }
    List items = object as List;
    return items.every((r) => r is ws.Resource);
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Resource].
   */
  bool _isSingleResource(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List<ws.Resource>;
    return resources.length == 1;
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Project].
   */
  bool _isProject(object) {
    if (!_isResourceList(object)) {
      return false;
    }
    return object.length == 1 && object.first is ws.Project;
  }

  /**
   * Returns true if `context` is a list with a single item, the item is a
   * [Project], and that project is under SCM.
   */
  bool _isScmProject(context) =>
      _isProject(context) && isUnderScm(context.first);

  /**
   * Returns true if `context` is a list with of items, all in the same project,
   * and that project is under SCM.
   */
  bool _isUnderScmProject(context) {
    if (context is! List) return false;
    if (context.isEmpty) return false;

    ws.Project project = context.first.project;

    if (!isUnderScm(project)) return false;

    for (var resource in context) {
      var resProject = resource.project;
      if (resProject == null || resProject != project) {
        return false;
      }
    }

    return true;
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Folder].
   */
  bool _isSingleFolder(Object object) {
    if (!_isSingleResource(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return (object as List).first is ws.Folder;
  }

  /**
   * Returns true if `object` is a list of top-level [Resource].
   */
  bool _isTopLevel(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return resources.every((ws.Resource r) => r.isTopLevel);
  }

  /**
   * Returns true if `object` is a top-level [File].
   */
  bool _isTopLevelFile(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return resources.first.project == null;
  }

  /**
   * Returns true if `object` is a list of File.
   */
  bool _isFileList(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return resources.every((r) => r is ws.File);
  }
}

abstract class SparkDialog {
  void show();
  void hide();
  Element get element;
}

abstract class SparkActionWithDialog extends SparkAction {
  SparkDialog _dialog;

  SparkActionWithDialog(Spark spark,
                        String id,
                        String name,
                        Element dialogElement)
      : super(spark, id, name) {
    _dialog = spark.createDialog(dialogElement);
    _dialog.element.querySelector("[primary]").onClick.listen((_) => _commit());
  }

  void _commit() { }

  Element getElement(String selectors) =>
      _dialog.element.querySelector(selectors);

  List<Element> getElements(String selectors) =>
      _dialog.element.querySelectorAll(selectors);

  Element _triggerOnReturn(String selectors) {
    var element = _dialog.element.querySelector(selectors);
    element.onKeyDown.listen((event) {
      if (event.keyCode == KeyCode.ENTER) {
        _commit();
        _dialog.hide();
      }
    });
    return element;
  }

  void _show() => _dialog.show();
}

class FileOpenInTabAction extends SparkAction implements ContextAction {
  FileOpenInTabAction(Spark spark) :
      super(spark, "file-open-in-tab", "Open in New Tab");

  void _invoke([List<ws.File> files]) {
    bool forceOpen = files.length > 1;
    files.forEach((ws.File file) {
      spark._selectInEditor(file, forceOpen: true, replaceCurrent: false);
    });
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isFileList(object);
}

class FileOpenAction extends SparkAction {
  FileOpenAction(Spark spark) : super(spark, "file-open", "Open File…") {
    addBinding("ctrl-o");
  }

  void _invoke([Object context]) {
    spark.openFile();
  }
}

class FileNewAction extends SparkActionWithDialog implements ContextAction {
  InputElement _nameElement;
  ws.Folder folder;

  FileNewAction(Spark spark, Element dialog)
      : super(spark, "file-new", "New File…", dialog) {
    addBinding("ctrl-n");
    _nameElement = _triggerOnReturn("#fileName");
  }

  void _invoke([List<ws.Resource> resources]) {
    folder = spark._getFolder(resources);
    if (folder != null) {
      _nameElement.value = '';
      _show();
    }
  }

  void _commit() {
    var name = _nameElement.value;
    if (name.isNotEmpty) {
      if (folder != null) {
        folder.createNewFile(name).then((file) {
          // Delay a bit to allow the files view to process the new file event.
          // TODO: This is due to a race condition in when the files view receives
          // the resource creation event; we should remove the possibility for
          // this to occur.
          Timer.run(() {
            spark._selectInEditor(file, forceOpen: true, replaceCurrent: true);
            spark._aceManager.focus();
          });
        }).catchError((e) {
          spark.showErrorMessage("Error Creating File", e.toString());
        });
      }
    }
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleResource(object) && !_isTopLevelFile(object);
}

class FileSaveAction extends SparkAction {
  FileSaveAction(Spark spark) : super(spark, "file-save", "Save") {
    addBinding("ctrl-s");
  }

  void _invoke([Object context]) => spark.editorManager.saveAll();
}

class FileDeleteAction extends SparkAction implements ContextAction {
  FileDeleteAction(Spark spark) : super(spark, "file-delete", "Delete");

  void _invoke([List<ws.Resource> resources]) {
    if (resources == null) {
      var sel = spark._filesController.getSelection();
      if (sel.isEmpty) return;
      resources = sel;
    }

    String message;

    if (resources.length == 1) {
      message = "Are you sure you want to delete '${resources.first.name}'?";
    } else {
      message = "Are you sure you want to delete ${resources.length} files?";
    }

    spark.askUserOkCancel(message, okButtonLabel: 'Delete').then((bool val) {
      if (val) {
        spark.workspace.pauseResourceEvents();
        Future.forEach(resources, (ws.Resource r) => r.delete()).catchError((e) {
          String ordinality = resources.length == 1 ? "File" : "Files";
          spark.showErrorMessage("Error Deleting ${ordinality}", e.toString());
        }).whenComplete(() {
          spark.workspace.resumeResourceEvents();
          spark.workspace.save();
        });
      }
    });
  }

  String get category => 'resource';

  bool appliesTo(Object object) => _isResourceList(object);
}

class FileRenameAction extends SparkActionWithDialog implements ContextAction {
  ws.Resource resource;
  InputElement _nameElement;

  FileRenameAction(Spark spark, Element dialog)
      : super(spark, "file-rename", "Rename…", dialog) {
    _nameElement = _triggerOnReturn("#renameFileName");
  }

  void _invoke([List<ws.Resource> resources]) {
    if (resources != null && resources.isNotEmpty) {
      resource = resources.first;
      _nameElement.value = resource.name;
      _show();
    }
  }

  void _commit() {
    if (_nameElement.value.isNotEmpty) {
      resource.rename(_nameElement.value).then((value) {
        spark._renameOpenEditor(resource);
      }).catchError((e) {
        spark.showErrorMessage("Error During Rename", e.toString());
      });
    }
  }

  String get category => 'resource';

  bool appliesTo(Object object) => _isSingleResource(object) && !_isTopLevel(object);
}

class ResourceCloseAction extends SparkAction implements ContextAction {
  ResourceCloseAction(Spark spark) : super(spark, "file-close", "Close");

  void _invoke([List<ws.Resource> resources]) {
    if (resources == null) {
      resources = spark._getSelection();
    }

    for (ws.Resource resource in resources) {
      spark.workspace.unlink(resource);
      if (resource is ws.File) {
        spark._closeOpenEditor(resource);
      } else if (resource is ws.Project) {
        resource.traverse().forEach(spark._closeOpenEditor);
      }
    }

    spark.workspace.save();
  }

  String get category => 'resource';

  bool appliesTo(Object object) => _isTopLevel(object);
}

class TabPreviousAction extends SparkAction {
  TabPreviousAction(Spark spark) : super(spark, "tab-prev", "Previous Tab") {
    addBinding('ctrl-shift-[');
    addBinding('ctrl-shift-tab', macBinding: 'macctrl-shift-tab');
  }

  void _invoke([Object context]) => spark.editorArea.gotoPreviousTab();
}

class TabNextAction extends SparkAction {
  TabNextAction(Spark spark) : super(spark, "tab-next", "Next Tab") {
    addBinding('ctrl-shift-]');
    addBinding('ctrl-tab', macBinding: 'macctrl-tab');
  }

  void _invoke([Object context]) => spark.editorArea.gotoNextTab();
}

class SpecificTabAction extends SparkAction {
  _SpecificTabKeyBinding _binding;

  SpecificTabAction(Spark spark) : super(spark, "tab-goto", "Goto Tab") {
    _binding = new _SpecificTabKeyBinding();
    bindings.add(_binding);
  }

  void _invoke([Object context]) {
    if (_binding.index < 1 && _binding.index > spark.editorArea.tabs.length) {
      return;
    }

    // Ctrl-1 to Ctrl-8. The user types in a 1-based key event; we convert that
    // into a 0-based into into the tabs.
    spark.editorArea.selectedTab = spark.editorArea.tabs[_binding.index - 1];
  }
}

class _SpecificTabKeyBinding extends KeyBinding {
  final int ONE_CODE = '1'.codeUnitAt(0);
  final int EIGHT_CODE = '8'.codeUnitAt(0);

  int index = -1;

  _SpecificTabKeyBinding() : super('ctrl-1');

  bool matches(KeyboardEvent event) {
    // If the user typed in a 1 to an 8, change this binding to match that key.
    // To match completely, the user will need to have used the `ctrl` modifier.
    if (event.keyCode >= ONE_CODE && event.keyCode <= EIGHT_CODE) {
      keyCode = event.keyCode;
      index = keyCode - ONE_CODE + 1;
    }

    return super.matches(event);
  }
}

class TabLastAction extends SparkAction {
  TabLastAction(Spark spark) : super(spark, "tab-last", "Last Tab") {
    addBinding("ctrl-9");
  }

  void _invoke([Object context]) {
    if (spark.editorArea.tabs.isNotEmpty) {
      spark.editorArea.selectedTab = spark.editorArea.tabs.last;
    }
  }
}

class TabCloseAction extends SparkAction {
  TabCloseAction(Spark spark) : super(spark, "tab-close", "Close") {
    addBinding("ctrl-w");
  }

  void _invoke([Object context]) {
    if (spark.editorArea.selectedTab != null) {
      spark.editorArea.remove(spark.editorArea.selectedTab);
    }
  }
}

class FileExitAction extends SparkAction {
  FileExitAction(Spark spark) : super(spark, "file-exit", "Quit") {
    addBinding('ctrl-q', linuxBinding: 'ctrl-shift-q');
  }

  void _invoke([Object context]) {
    spark.close().then((_) {
      chrome.app.window.current().close();
    });
  }
}

class ApplicationRunAction extends SparkAction implements ContextAction {
  ApplicationRunAction(Spark spark) : super(
      spark, "application-run", "Run Application") {
    addBinding("ctrl-r");
    enabled = false;
    spark.focusManager.onResourceChange.listen((r) => _updateEnablement(r));
  }

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }

    Completer completer = new Completer();
    ProgressJob job = new ProgressJob("Running application…", completer);
    spark.launchManager.run(resource).then((_) {
      completer.complete();
    }).catchError((e) {
      completer.complete();
      spark.showErrorMessage('Error Running Application', '${e}');
    });
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  bool _appliesTo(ws.Resource resource) {
    return spark.launchManager.canRun(resource);
  }

  void _updateEnablement(ws.Resource resource) {
    enabled = _appliesTo(resource);
  }
}

abstract class PackageGetAction extends SparkAction implements ContextAction {
  PackageGetAction(Spark spark, String id, String name) :
    super(spark, id, name);

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }

    spark.jobManager.schedule(_createJob(resource.project));
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  Job _createJob(ws.Project project);

  bool _appliesTo(ws.Resource resource);
}

class PubGetAction extends PackageGetAction {
  PubGetAction(Spark spark) : super(spark, "pub-get", "Pub Get");

  Job _createJob(ws.Project project) => new PubGetJob(spark, project);

  bool _appliesTo(ws.Resource resource) =>
      spark.pubManager.properties.isPackageResource(resource);
}

class BowerGetAction extends PackageGetAction {
  BowerGetAction(Spark spark) : super(spark, "bower-install", "Bower Install");

  Job _createJob(ws.Project project) => new BowerGetJob(spark, project);

  bool _appliesTo(ws.Resource resource) =>
      spark.bowerManager.properties.isPackageResource(resource);
}

class PubUpgradeAction extends SparkAction implements ContextAction {
  PubUpgradeAction(Spark spark) : super(spark, "pub-upgrade", "Pub Upgrade");

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }

    spark.jobManager.schedule(new PubUpgradeJob(spark, resource.project));
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  bool _appliesTo(ws.Resource resource) =>
      spark.pubManager.properties.isPackageResource(resource);
}

/**
 * A context menu item to compile a Dart file to JavaScript. Currently this is
 * only available for Dart files in a chrome app.
 */
class CompileDartAction extends SparkAction implements ContextAction {
  CompileDartAction(Spark spark) : super(spark, "dart-compile", "Compile to JavaScript");

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }

    spark.jobManager.schedule(
        new CompileDartJob(spark, resource, resource.name));
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  bool _appliesTo(ws.Resource resource) {
    bool isDartFile = resource is ws.File && resource.project != null
        && resource.name.endsWith('.dart');

    if (!isDartFile) return false;

    return resource.parent.getChild('manifest.json') != null;
  }
}

class ResourceRefreshAction extends SparkAction implements ContextAction {
  ResourceRefreshAction(Spark spark) : super(
      spark, "resource-refresh", "Refresh") {
    // On Chrome OS, bind to the dedicated refresh key.
    chrome.runtime.getPlatformInfo().then((Map m) {
      if (new PlatformInfo.fromMap(m).isCros) {
        addBinding('f5', linuxBinding: 'f3');
      } else {
        addBinding('f5');
      }
    });
  }

  void _invoke([context]) {
    List<ws.Resource> resources;

    if (context == null) {
      resources = [spark.focusManager.currentResource];
    } else {
      resources = context;
    }

    ResourceRefreshJob job = new ResourceRefreshJob(resources);
    spark.jobManager.schedule(job);
  }

  String get category => 'resource';

  bool appliesTo(context) => _isResourceList(context) && !_isTopLevelFile(context);
}

class PrevMarkerAction extends SparkAction {
  PrevMarkerAction(Spark spark) : super(
      spark, "marker-prev", "Previous Marker") {
    addBinding("ctrl-shift-p");
  }

  void _invoke([Object context]) {
    spark._aceManager.selectPrevMarker();
  }
}

class NextMarkerAction extends SparkAction {
  NextMarkerAction(Spark spark) : super(
      spark, "marker-next", "Next Marker") {
    // TODO: We probably don't want to bind to 'print'. Perhaps there's a good
    // keybinding we can borrow from Chrome?
    addBinding("ctrl-p");
  }

  void _invoke([Object context]) {
    spark._aceManager.selectNextMarker();
  }
}

class FolderNewAction extends SparkActionWithDialog implements ContextAction {
  InputElement _nameElement;
  ws.Folder folder;

  FolderNewAction(Spark spark, Element dialog)
      : super(spark, "folder-new", "New Folder…", dialog) {
    addBinding("ctrl-shift-n");
    _nameElement = _triggerOnReturn("#folderName");
  }

  void _invoke([List<ws.Folder> folders]) {
    folder = spark._getFolder(folders);
    _nameElement.value = '';
    _show();
  }

  void _commit() {
    final String name = _nameElement.value;
    if (name.isNotEmpty) {
      folder.createNewFolder(name).then((folder) {
        // Delay a bit to allow the files view to process the new file event.
        Timer.run(() {
          spark._filesController.selectFile(folder);
        });
      }).catchError((e) {
        spark.showErrorMessage("Error Creating Folder", e.toString());
      });
    }
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleFolder(object);
}

class FormatAction extends SparkAction {
  FormatAction(Spark spark) : super(spark, 'edit-format', 'Format') {
    // TODO: I do not like this binding, but can't think of a better one.
    addBinding('ctrl-shift-1');
  }

  void _invoke([Object context]) {
    ws.File file = spark.editorManager.currentFile;
    for (Editor editor in spark.editorManager.editors) {
      if (editor.file == file) {
        if (editor is TextEditor) {
          editor.format();
        }
        break;
      }
    }
  }
}

/// Transfers the focus to the search box
class SearchAction extends SparkAction {
  SearchAction(Spark spark) : super(spark, 'search', 'Search') {
    addBinding('ctrl-shift-f');
  }

  @override
  void _invoke([Object context]) {
    spark.getUIElement('#searchBox').focus();
  }
}

class FocusMainMenuAction extends SparkAction {
  FocusMainMenuAction(Spark spark)
      : super(spark, 'focusMainMenu', 'Focus Main Menu') {
    addBinding('f10');
  }

  @override
  void _invoke([Object context]) {
    spark.getUIElement('#mainMenu').focus();
  }
}

class NewProjectAction extends SparkActionWithDialog {
  InputElement _nameElt;
  List<InputElement> _jsDepsElts;
  ws.Folder folder;

  NewProjectAction(Spark spark, Element dialog)
      : super(spark, "project-new", "New Project…", dialog) {
    _nameElt = _triggerOnReturn("#name");
    _jsDepsElts = getElements('[name="jsDeps"]');
  }

  void _invoke([context]) {
    _nameElt.value = '';
    _show();
  }

  void _commit() {
    final name = _nameElt.value.trim();

    if (name.isEmpty) return;

    spark.projectLocationManager.createNewFolder(name)
        .then((LocationResult location) {
      if (location == null) {
        return new Future.value();
      }

      ws.WorkspaceRoot root;
      final locationEntry = location.entry;

      if (location.isSync) {
        root = new ws.SyncFolderRoot(locationEntry);
      } else {
        root = new ws.FolderChildRoot(location.parent, locationEntry);
      }

      return new Future.value().then((_) {
        List<ProjectTemplate> templates = [];

        final globalVars = {
            'projectName': name,
            'sourceName': name.toLowerCase()
        };

        final InputElement projectTypeElt =
            getElement('input[name="type"]:checked');
        templates.add(
            new ProjectTemplate(projectTypeElt.value, globalVars));

        List<String> jsDeps = [];
        for (final elt in _jsDepsElts) {
          // NOTE: This test will get both the checkboxes and the textbox.
          if ((elt.type == "checkbox" && elt.checked) ||
              (elt.type == "textarea" && elt.value.isNotEmpty)) {
            jsDeps.add(elt.value);
          }
        }
        if (jsDeps.isNotEmpty) {
          final localVars = {
              'dependencies': jsDeps.join(',\n    ')
          };
          templates.add(
              new ProjectTemplate("bower-deps", globalVars, localVars));
        }

        return new ProjectBuilder(locationEntry, templates).build();

      }).then((_) {
        return spark.workspace.link(root).then((ws.Project project) {
          spark.showSuccessMessage('Created ${project.name}');
          Timer.run(() {
            spark._selectResource(ProjectBuilder.getMainResourceFor(project));

            // Run Pub if the new project has a pubspec file.
            if (spark.pubManager.properties.isProjectWithPackages(project)) {
              spark.jobManager.schedule(new PubGetJob(spark, project));
            }

            // Run Bower if the new project has a bower.json file.
            if (spark.bowerManager.properties.isProjectWithPackages(project)) {
              spark.jobManager.schedule(new BowerGetJob(spark, project));
            }
          });
          spark.workspace.save();
        });
      });
    }).catchError((e) {
      spark.showErrorMessage('Error Creating Project', '${e}');
    });
  }
}

class FolderOpenAction extends SparkAction {
  FolderOpenAction(Spark spark) : super(spark, "folder-open", "Open Folder…");

  void _invoke([Object context]) {
    spark.openFolder();
  }
}

class ApplicationPushAction extends SparkActionWithDialog implements ContextAction {
  InputElement _pushUrlElement;
  ws.Container deployContainer;

  ApplicationPushAction(Spark spark, Element dialog)
      : super(spark, "application-push", "Deploy to Mobile", dialog) {
    _pushUrlElement = _triggerOnReturn("#pushUrl");
    enabled = false;
    spark.focusManager.onResourceChange.listen((r) => _updateEnablement(r));
  }

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }

    deployContainer = getAppContainerFor(resource);

    _show();
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  bool _appliesTo(ws.Resource resource) {
    return getAppContainerFor(resource) != null;
  }

  void _updateEnablement(ws.Resource resource) {
    enabled = _appliesTo(resource);
  }

  void _commit() {
    String type = getElement('input[name="type"]:checked').id;
    Job job;
    if (type == 'adb') {
      job = new _HarnessPushJob.pushToAdb(spark, deployContainer);
    } else {
      String url = _pushUrlElement.value;
      // TODO(braden): Input validation.
      job = new _HarnessPushJob.pushToUrl(spark, deployContainer, url);
    }
    spark.jobManager.schedule(job);
  }
}

class _HarnessPushJob extends Job {
  final Spark spark;
  final ws.Container deployContainer;
  String _url;
  bool _adb = false;

  _HarnessPushJob.pushToAdb(this.spark, this.deployContainer)
      : super('Deploying via ADB…') {
    _adb = true;
  }

  _HarnessPushJob.pushToUrl(this.spark, this.deployContainer, this._url)
      : super('Deploying to mobile…') { }

  Future run(ProgressMonitor monitor) {
    if (_adb) {
      spark.showProgressDialog('#pushADBProgressDialog');
    }

    HarnessPush harnessPush = new HarnessPush(deployContainer,
        spark.localPrefs);

    Future push = _adb ? harnessPush.pushADB(monitor) :
        harnessPush.push(_url, monitor);
    return push.then((_) {
      if (_adb) {
        spark.hideProgressDialog();
      }
      spark.showSuccessMessage('Successfully pushed');
    }).catchError((e) {
      if (_adb) {
        spark.hideProgressDialog();
      }
      spark.showMessage('Push failure', e.toString());
    });
  }
}

class PropertiesAction extends SparkActionWithDialog implements ContextAction {
  ws.Resource _selectedResource;
  Element _titleElement;
  HtmlElement _propertiesElement;

  PropertiesAction(Spark spark, Element dialog)
      : super(spark, 'properties', 'Properties…', dialog) {
    _titleElement = getElement('#propertiesDialog .modal-title');
    _propertiesElement = getElement('#propertiesDialog .modal-body');
  }

  void _invoke([List context]) {
    _selectedResource = context.first;
    final String type = _selectedResource is ws.Project ? 'Project' :
      _selectedResource is ws.Container ? 'Folder' : 'File';
    _titleElement.text = '${type} Properties';
    _propertiesElement.innerHtml = '';
    _buildProperties().then((_) => _show());
  }

  Future _buildProperties() {
    _addProperty(_propertiesElement, 'Name', _selectedResource.name);
    return _getLocation().then((location) {
      _addProperty(_propertiesElement, 'Location', location);
    }).then((_) {
      GitScmProjectOperations gitOperations =
          spark.scmManager.getScmOperationsFor(_selectedResource.project);

      if (gitOperations != null) {
        return gitOperations.getConfigMap().then((Map<String, dynamic> map) {
          final String repoUrl = map['url'];
          _addProperty(_propertiesElement, 'Repository', repoUrl);
        }).catchError((e) {
          _addProperty(_propertiesElement, 'Repository',
              '<error retrieving Git data>');
        });
      }
    }).then((_) {
      return _selectedResource.entry.getMetadata().then((meta) {
        if (_selectedResource.entry is FileEntry) {
          final String size = _nf.format(meta.size);
          _addProperty(_propertiesElement, 'Size', '$size bytes');
        }

        final String lastModified =
            new DateFormat.yMMMd().add_jms().format(meta.modificationTime);
        _addProperty(_propertiesElement, 'Last Modified', lastModified);
      });
    });
  }

  Future<String> _getLocation() {
    return chrome.fileSystem.getDisplayPath(_selectedResource.entry)
        .catchError((e) {
      // SyncFS from ChromeBook falls in here.
      return _selectedResource.entry.fullPath;
    });
  }

  void _addProperty(HtmlElement parent, String key, String value) {
    Element div = new DivElement()..classes.add('form-group');
    parent.children.add(div);

    Element label = new LabelElement()..text = key;
    Element element = new ParagraphElement()..text = value
        ..className = 'form-control-static'
        ..attributes["selectableTxt"] = "";

    div.children.addAll([label, element]);
  }

  String get category => 'properties';

  bool appliesTo(context) => true;
}

/* Git operations */

class GitCloneAction extends SparkActionWithDialog {
  InputElement _repoUrlElement;

  GitCloneAction(Spark spark, Element dialog)
      : super(spark, "git-clone", "Git Clone…", dialog) {
    _repoUrlElement = _triggerOnReturn("#gitRepoUrl");
  }

  void _invoke([Object context]) {
    // Select any previous text in the URL field.
    Timer.run(_repoUrlElement.select);

    _show();
  }

  void _commit() {
    String url = _repoUrlElement.value;
    String projectName;

    if (url.isEmpty) return;

    // TODO(grv): Add verify checks.

    // Add `'.git` to the given url unless it ends with `/`.
    if (url.endsWith('/')) {
      projectName = url.substring(0, url.length - 1).split('/').last;
    } else {
      projectName = url.split('/').last;
    }

    if (projectName.endsWith('.git')) {
      projectName = projectName.substring(0, projectName.length - 4);
    }

    _GitCloneJob job = new _GitCloneJob(url, projectName, spark);
    spark.jobManager.schedule(job);
  }
}

class GitPullAction extends SparkAction implements ContextAction {
  GitPullAction(Spark spark) : super(spark, "git-pull", "Pull from Origin");

  void _invoke([context]) {
    var project = context.first.project;
    var operations = spark.scmManager.getScmOperationsFor(project);

    spark.jobManager.schedule(new _GitPullJob(operations, spark));
  }

  String get category => 'git';

  bool appliesTo(context) => _isScmProject(context);
}

class GitBranchAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  GitScmProjectOperations gitOperations;
  InputElement _branchNameElement;

  GitBranchAction(Spark spark, Element dialog)
      : super(spark, "git-branch", "Create Branch…", dialog) {
    _branchNameElement = _triggerOnReturn("#gitBranchName");
  }

  void _invoke([context]) {
    project = context.first;
    gitOperations = spark.scmManager.getScmOperationsFor(project);
    _show();
  }

  void _commit() {
    // TODO(grv): Add verify checks.
    _GitBranchJob job = new _GitBranchJob(gitOperations, _branchNameElement.value);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isScmProject(context);
}

class GitCommitAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  GitScmProjectOperations gitOperations;
  TextAreaElement _commitMessageElement;
  InputElement _userNameElement;
  InputElement _userEmailElement;
  Element _gitStatusElement;
  DivElement _gitChangeElement;
  bool _needsFillNameEmail;
  String _gitName;
  String _gitEmail;

  List<ws.File> modifiedFileList = [];
  List<ws.File> addedFileList = [];

  GitCommitAction(Spark spark, Element dialog)
      : super(spark, "git-commit", "Commit Changes…", dialog) {
    _commitMessageElement = getElement("#commitMessage");
    _userNameElement = getElement('#gitName');
    _userEmailElement = getElement('#gitEmail');
    _gitStatusElement = getElement('#gitStatus');
    _gitChangeElement = getElement('#gitChangeList');
    getElement('#gitStatusDetail').onClick.listen((e) {
      _gitChangeElement.style.display =
          _gitChangeElement.style.display == 'none' ? 'block' : 'none';
    });
  }

  void _invoke([context]) {
    project = context.first.project;
    gitOperations = spark.scmManager.getScmOperationsFor(project);
    modifiedFileList.clear();
    addedFileList.clear();
    spark.syncPrefs.getValue("git-user-info").then((String value) {
      _gitName = null;
      _gitEmail = null;
      if (value != null) {
        Map<String,String> info = JSON.decode(value);
        _needsFillNameEmail = false;
        _gitName = info['name'];
        _gitEmail = info['email'];
      } else {
        _needsFillNameEmail = true;
      }
      getElement('#gitUserInfo').classes.toggle('hidden', !_needsFillNameEmail);
      _commitMessageElement.value = '';
      _userNameElement.value = '';
      _userEmailElement.value = '';
      _gitChangeElement.text = '';
      _gitChangeElement.style.display = 'none';

      _addGitStatus();

      _show();
    });
  }

  void _addGitStatus() {
    _calculateScmStatus(project);
    modifiedFileList.forEach((file) {
      _gitChangeElement.innerHtml += 'Modified:&emsp;' + file.path + '<br/>';
    });
    addedFileList.forEach((file){
      _gitChangeElement.innerHtml += 'Added:&emsp;' + file.path + '<br/>';
    });
    final int modifiedCnt = modifiedFileList.length;
    final int addedCnt = addedFileList.length;
    if (modifiedCnt + addedCnt == 0) {
      _gitStatusElement.text = "Nothing to commit.";
    } else {
      _gitStatusElement.text =
          '$modifiedCnt ${(modifiedCnt > 1) ? 'files' : 'file'} modified, ' +
          '$addedCnt ${(addedCnt > 1) ? 'files' : 'file'} added.';
    // TODO(sunglim): show the count of deletetd files.
    }
  }

  void _calculateScmStatus(ws.Folder folder) {
    folder.getChildren().forEach((resource) {
      if (resource is ws.Folder) {
        if (resource.isScmPrivate()) {
          return;
        }
        _calculateScmStatus(resource);
      } else if (resource is ws.File) {
        FileStatus status = gitOperations.getFileStatus(resource);
        if (status == FileStatus.MODIFIED) {
          modifiedFileList.add(resource);
        } else if (status == FileStatus.UNTRACKED) {
          addedFileList.add(resource);
        }
      }
    });
  }

  void _commit() {
    if (_needsFillNameEmail) {
      _gitName = _userNameElement.value;
      _gitEmail = _userEmailElement.value;
      String encoded = JSON.encode({'name': _gitName, 'email': _gitEmail});
      spark.syncPrefs.setValue("git-user-info", encoded).then((_) {
        _startJob();
      });
    } else {
      _startJob();
    }
  }

  void _startJob() {
    // TODO(grv): Add verify checks.
    _GitCommitJob job = new _GitCommitJob(
        gitOperations, _gitName, _gitEmail, _commitMessageElement.value, spark);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isUnderScmProject(context);
}

class GitCheckoutAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  GitScmProjectOperations gitOperations;
  SelectElement _selectElement;

  GitCheckoutAction(Spark spark, Element dialog)
      : super(spark, "git-checkout", "Switch Branch…", dialog) {
    _selectElement = getElement("#gitCheckout");
  }

  void _invoke([List context]) {
    project = context.first;
    gitOperations = spark.scmManager.getScmOperationsFor(project);
    String currentBranchName = gitOperations.getBranchName();
    (getElement('#currentBranchName') as InputElement).value = currentBranchName;

    // Clear out the old select options.
    _selectElement.length = 0;

    gitOperations.getAllBranchNames().then((List<String> branchNames) {
      branchNames.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (String branchName in branchNames) {
        _selectElement.append(
            new OptionElement(data: branchName, value: branchName));
      }
      _selectElement.selectedIndex = branchNames.indexOf(currentBranchName);
    });

    _show();
  }

  void _commit() {
    // TODO(grv): Add verify checks.
    String branchName = _selectElement.options[
        _selectElement.selectedIndex].value;
    _GitCheckoutJob job = new _GitCheckoutJob(gitOperations, branchName, spark);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isScmProject(context);
}

class GitPushAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  GitScmProjectOperations gitOperations;
  DivElement _commitsList;
  String _gitUsername;
  String _gitPassword;
  bool _needsUsernamePassword;

  GitPushAction(Spark spark, Element dialog)
      : super(spark, "git-push", "Push to Origin…", dialog) {
    _commitsList = getElement('#gitCommitList');
  }

  void _invoke([context]) {
    project = context.first;

    gitOperations = spark.scmManager.getScmOperationsFor(project);
    gitOperations.getPendingCommits().then((List<CommitInfo> commits) {
      // Fill commits.
      _commitsList.innerHtml = '';
      String summaryString = commits.length == 1 ? "1 commit" : "${commits.length} commits";
      Element title = document.createElement("h1");
      title.appendText(summaryString);
      _commitsList.append(title);
      commits.forEach((CommitInfo info) {
        CommitMessageView commitView = new CommitMessageView();
        commitView.commitInfo = info;
        _commitsList.children.add(commitView);
      });

      spark.syncPrefs.getValue("git-auth-info").then((String value) {
        _gitUsername = null;
        _gitPassword = null;
        if (value != null) {
          Map<String,String> info = JSON.decode(value);
          _needsUsernamePassword = false;
          _gitUsername = info['username'];
          _gitPassword = info['password'];
        }
        else {
          _needsUsernamePassword = true;
        }
        _show();
      });
    }).catchError((e) {
      spark.showErrorMessage('Push failed', 'No commits to push');
    });
  }

  void _push() {
    _GitPushJob job = new _GitPushJob(gitOperations, _gitUsername, _gitPassword, spark);
    spark.jobManager.schedule(job);
  }

  void _commit() {
    if (_needsUsernamePassword) {
      Timer.run(() {
        // In a timer to let the previous dialog dismiss properly.
        GitAuthenticationDialog.request(spark).then((info) {
          _gitUsername = info['username'];
          _gitPassword = info['password'];
          _push();
        }).catchError((_) {
          // Cancelled authentication: do nothing.
        });
      });
    } else {
      _push();
    }
  }

  String get category => 'git';

  bool appliesTo(context) => _isScmProject(context);
}

class GitResolveConflictsAction extends SparkAction implements ContextAction {
  GitResolveConflictsAction(Spark spark) :
      super(spark, "git-resolve-conflicts", "Resolve Conflicts");

  void _invoke([context]) {
    ws.Resource file = _getResource(context);
    ScmProjectOperations operations =
        spark.scmManager.getScmOperationsFor(file.project);

    operations.markResolved(file);
  }

  String get category => 'git';

  bool appliesTo(context) => _isUnderScmProject(context) &&
      _isSingleResource(context) && _fileHasConflicts(context);

  bool _fileHasConflicts(context) {
    ws.Resource file = _getResource(context);
    ScmProjectOperations operations =
        spark.scmManager.getScmOperationsFor(file.project);
    return operations.getFileStatus(file) == FileStatus.UNMERGED;
  }

  ws.Resource _getResource(context) {
    if (context is List) {
      return context.isNotEmpty ? context.first : null;
    } else {
      return null;
    }
  }
}

class GitRevertChangesAction extends SparkAction implements ContextAction {
  GitRevertChangesAction(Spark spark) :
      super(spark, "git-revert-changes", "Revert Changes…");

  void _invoke([List resources]) {
    ScmProjectOperations operations =
        spark.scmManager.getScmOperationsFor(resources.first.project);

    String text = (resources.length == 1 ?
        resources.first.name :
        '${resources.length} resources');
    text = 'Revert changes for ${text}?';

    // Show a yes/no dialog.
    spark.askUserOkCancel(text, okButtonLabel: 'Revert').then((bool val) {
      if (val) {
        operations.revertChanges(resources).then((_) {
          resources.first.project.refresh();
        });
      }
    });
  }

  String get category => 'git';

  bool appliesTo(context) => _isUnderScmProject(context) &&
      _filesAreModified(context);

  bool _filesAreModified(List resources) {
    ScmProjectOperations operations =
        spark.scmManager.getScmOperationsFor(resources.first.project);

    for (ws.Resource resource in resources) {
      // TODO: Should we also check UNTRACKED?
      if (operations.getFileStatus(resource) != FileStatus.MODIFIED) {
        return false;
      }
    }

    return true;
  }
}

class _GitCloneJob extends Job {
  String url;
  String _projectName;
  Spark spark;

  _GitCloneJob(this.url, String projectName, this.spark)
      : super("Cloning ${projectName}…") {
    _projectName = projectName;
  }

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return spark.projectLocationManager.createNewFolder(_projectName).then((LocationResult location) {
      if (location == null) {
        return new Future.value();
      }

      ScmProvider scmProvider = getProviderType('git');

      return scmProvider.clone(url, location.entry).then((_) {
        ws.WorkspaceRoot root;

        if (location.isSync) {
          root = new ws.SyncFolderRoot(location.entry);
        } else {
          root = new ws.FolderChildRoot(location.parent, location.entry);
        }

        return spark.workspace.link(root).then((ws.Project project) {
          spark.showSuccessMessage('Cloned into ${project.name}');
          Timer.run(() {
            spark._filesController.selectFile(project);
            spark._filesController.setFolderExpanded(project);
          });
          spark.workspace.save();
        });
      });
    }).catchError((e) {
      if (e != null) {
        spark.showErrorMessage('Error cloning ${_projectName}', '${e}');
      }
    });
  }
}

class _GitPullJob extends Job {
  GitScmProjectOperations gitOperations;
  Spark spark;

  _GitPullJob(this.gitOperations, this.spark) : super("Pulling…");

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    // TODO: We'll want a way to indicate to the user what files changed and if
    // there were any merge problems.
    return gitOperations.pull().then((_) {
      spark.showSuccessMessage('Pull successful');
    }).catchError((e) {
      spark.showErrorMessage('Git Pull Status', e.toString());
    });
  }
}

class _GitBranchJob extends Job {
  GitScmProjectOperations gitOperations;
  String _branchName;
  String url;

  _GitBranchJob(this.gitOperations, String branchName)
      : super("Creating ${branchName}…") {
    _branchName = branchName;
  }

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return gitOperations.createBranch(_branchName).then((_) {
      return gitOperations.checkoutBranch(_branchName).then((_) {
        SparkModel.instance.showSuccessMessage('Created ${_branchName}');
      });
    }).catchError((e) {
      SparkModel.instance.showErrorMessage(
          'Error creating branch ${_branchName}', e.toString());
    });
  }
}

class _GitCommitJob extends Job {
  GitScmProjectOperations gitOperations;
  String _commitMessage;
  String _userName;
  String _userEmail;
  Spark spark;

  _GitCommitJob(this.gitOperations, this._userName, this._userEmail,
      this._commitMessage, this.spark) : super("Committing…");

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return gitOperations.commit(_userName, _userEmail, _commitMessage).
        then((_) {
      spark.showSuccessMessage('Committed changes');
    }).catchError((e) {
      spark.showErrorMessage('Error committing changes', e.toString());
    });
  }
}

class _GitCheckoutJob extends Job {
  GitScmProjectOperations gitOperations;
  String _branchName;
  Spark spark;

  _GitCheckoutJob(this.gitOperations, String branchName, this.spark)
      : super("Switching to ${branchName}…") {
    _branchName = branchName;
  }

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return gitOperations.checkoutBranch(_branchName).then((_) {
      spark.showSuccessMessage('Switched to branch ${_branchName}');
    }).catchError((e) {
      spark.showErrorMessage('Error switching to ${_branchName}', e.toString());
    });
  }
}

class _OpenFolderJob extends Job {
  Spark spark;
  chrome.DirectoryEntry _entry;

  _OpenFolderJob(chrome.DirectoryEntry entry, this.spark)
      : super("Opening ${entry.fullPath}…") {
    _entry = entry;
  }

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return spark.workspace.link(
        new ws.FolderRoot(_entry)).then((ws.Resource resource) {
      Timer.run(() {
        spark._filesController.selectFile(resource);
        spark._filesController.setFolderExpanded(resource);
      });
      return spark.workspace.save();
    }).then((_) {
      spark.showSuccessMessage('Opened folder ${_entry.fullPath}');
    }).catchError((e) {
      spark.showErrorMessage('Error opening folder ${_entry.fullPath}',
          e.toString());
    });
  }
}

class _GitPushJob extends Job {
  GitScmProjectOperations gitOperations;
  Spark spark;
  String username;
  String password;

  _GitPushJob(this.gitOperations, this.username, this.password, this.spark)
      : super("Pushing changes…") {
  }

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return gitOperations.push(username, password).then((_) {
      spark.showSuccessMessage('Changes pushed successfully');
    }).catchError((e) {
      spark.showErrorMessage('Error while pushing changes', e.toString());
    });
  }
}

abstract class PackageManagementJob extends Job {
  final Spark _spark;
  final ws.Project _project;
  final String _commandName;

  PackageManagementJob(this._spark, this._project, this._commandName) :
      super('Getting packages…');

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    return _run().then((_) {
      _spark.showSuccessMessage("Successfully ran $_commandName");
    }).catchError((e) {
      _spark.showErrorMessage("Error while running $_commandName", e.toString());
    });
  }

  Future _run();
}

class PubGetJob extends PackageManagementJob {
  PubGetJob(Spark spark, ws.Project project) :
      super(spark, project, 'pub get');

  Future _run() => _spark.pubManager.installPackages(_project);
}

class PubUpgradeJob extends PackageManagementJob {
  PubUpgradeJob(Spark spark, ws.Project project) :
      super(spark, project, 'pub upgrade');

  Future _run() => _spark.pubManager.upgradePackages(_project);
}

class BowerGetJob extends PackageManagementJob {
  BowerGetJob(Spark spark, ws.Project project) :
      super(spark, project, 'bower install');

  Future _run() => _spark.bowerManager.installPackages(_project);
}

class CompileDartJob extends Job {
  final Spark spark;
  final ws.File file;

  CompileDartJob(this.spark, this.file, String fileName) :
      super('Compiling ${fileName}…');

  Future run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    CompilerService compiler = spark.services.getService("compiler");

    return compiler.compileFile(file, csp: true).then((CompilerResult result) {
      if (!result.getSuccess()) {
        throw result;
      }

      return getCreateFile(file.parent, '${file.name}.js').then((ws.File file) {
        return file.setContents(result.output);
      });
    }).catchError((e) {
      spark.showErrorMessage('Error Compiling ${file.name}', '${e}');
    });
  }

  Future<ws.File> getCreateFile(ws.Folder parent, String name) {
    ws.File file = parent.getChild(name);
    if (file == null) {
      return parent.createNewFile(name);
    } else {
      return new Future.value(file);
    }
  }
}

class ResourceRefreshJob extends Job {
  final List<ws.Project> resources;

  ResourceRefreshJob(this.resources) : super('Refreshing…');

  Future run(ProgressMonitor monitor) {
    List<ws.Project> projects = resources.map((r) => r.project).toSet().toList();

    monitor.start('', projects.length);

    Completer completer = new Completer();

    var consumeProject;
    consumeProject = () {
      ws.Project project = projects.removeAt(0);

      project.refresh().whenComplete(() {
        monitor.worked(1);

        if (projects.isEmpty) {
          completer.complete();
        } else {
          Timer.run(consumeProject);
        }
      });
    };

    Timer.run(consumeProject);

    return completer.future;
  }
}

// TODO(terry):  When only polymer overlays are used remove _initialized and
//               isPolymer's defintion and usage.
class AboutSparkAction extends SparkActionWithDialog {
  bool _initialized = false;

  AboutSparkAction(Spark spark, Element dialog)
      : super(spark, "help-about", "About Spark", dialog);

  void _invoke([Object context]) {
    if (!_initialized) {
      var checkbox = getElement('#analyticsCheck');
      checkbox.checked = _isTrackingPermitted;
      checkbox.onChange.listen((e) => _isTrackingPermitted = checkbox.checked);

      getElement('#aboutVersion').text = spark.appVersion;

      _initialized = true;
    }

    _show();
  }
}

class SettingsAction extends SparkActionWithDialog {
  bool _initialized = false;

  SettingsAction(Spark spark, Element dialog)
      : super(spark, "settings", "Settings", dialog);

  void _invoke([Object context]) {
    if (!_initialized) {
      _initialized = true;
    }

    spark.setGitSettingsResetDoneVisible(false);

    var whitespaceCheckbox = getElement('#stripWhitespace');

    // Wait for each of the following to (simultaneously) complete before
    // showing the dialog:
    Future.wait([
      spark.editorManager.stripWhitespaceOnSave.whenLoaded
          .then((BoolCachedPreference pref) {
            whitespaceCheckbox.checked = pref.value;
      }), new Future.value().then((_) {
        // For now, don't show the location field on Chrome OS; we always use syncFS.
        if (_isCros()) {
          return null;
        } else {
          return _showRootDirectory();
        }
      })
    ]).then((_) {
      _show();
      whitespaceCheckbox.onChange.listen((e) {
        spark.editorManager.stripWhitespaceOnSave.value =
            whitespaceCheckbox.checked;
      });
    });
  }

  Future _showRootDirectory() {
    return spark.localPrefs.getValue('projectFolder').then((folderToken) {
      if (folderToken == null) {
        getElement('#directory-label').text = '';
        return new Future.value();
      }
      return chrome.fileSystem.restoreEntry(folderToken).then((chrome.Entry entry) {
        return chrome.fileSystem.getDisplayPath(entry).then((path) {
          getElement('#directory-label').text = path;
        });
      });
    });
  }
}

class RunTestsAction extends SparkAction {
  RunTestsAction(Spark spark) : super(spark, "run-tests", "Run Tests") {
    if (spark.developerMode) {
      addBinding('ctrl-shift-alt-t');
    }
  }

  _invoke([Object context]) => spark._testDriver.runTests();
}

class WebStorePublishAction extends SparkActionWithDialog {
  bool _initialized = false;
  static final int NEWAPP = 1;
  static final int EXISTING = 2;
  int _type = NEWAPP;
  InputElement _newInput;
  InputElement _existingInput;
  InputElement _appIdInput;
  ws.Resource _resource;

  WebStorePublishAction(Spark spark, Element dialog)
      : super(spark, "webstore-publish", "Publish to Chrome Web Store", dialog) {
    enabled = false;
    spark.focusManager.onResourceChange.listen((r) => _updateEnablement(r));
  }

  void _invoke([Object context]) {
    if (!_initialized) {
      _newInput = getElement('input[value=new]');
      _existingInput = getElement('input[value=existing]');
      _appIdInput = getElement('#appID');
      _enableInput();

      _newInput.onChange.listen((e) => _enableInput());
      _existingInput.onChange.listen((e) => _enableInput());
      _initialized = true;
    }

    _resource = spark.focusManager.currentResource;
    _show();
  }

  void _enableInput() {
    int type = NEWAPP;
    if (_newInput.checked) {
      type = NEWAPP;
    }
    if (_existingInput.checked) {
      type = EXISTING;
    }
    _appIdInput.disabled = (type != EXISTING);
    if (type == EXISTING) {
      _appIdInput.focus();
    }
  }

  void _commit() {
    String appID = null;
    if (_existingInput.checked) {
      appID = _appIdInput.value;
    }
    _WebStorePublishJob job =
        new _WebStorePublishJob(spark, getAppContainerFor(_resource), appID);
    spark.jobManager.schedule(job);
  }

  void _updateEnablement(ws.Resource resource) {
    enabled = getAppContainerFor(resource) != null;
  }
}

class _WebStorePublishJob extends Job {
  ws.Container _container;
  String _appID;
  Spark spark;

  _WebStorePublishJob(this.spark, this._container, this._appID)
      : super("Publishing to Chrome Web Store…");

  Future run(ProgressMonitor monitor) {
    monitor.start(name, _appID == null ? 5 : 6);

    if (_container == null) {
      spark.showErrorMessage('Error while publishing the application',
          'The manifest.json file of the application has not been found.');
      return null;
    }

    return ws_utils.archiveContainer(_container).then((List<int> archivedData) {
      monitor.worked(1);
      WebStoreClient wsc = new WebStoreClient();
      return wsc.authenticate().then((_) {
        monitor.worked(1);
        return wsc.uploadItem(archivedData, identifier: _appID).then((String uploadedAppID) {
          monitor.worked(3);
          if (_appID == null) {
            spark.showUploadedAppDialog(uploadedAppID);
          } else {
            return wsc.publish(uploadedAppID).then((_) {
              monitor.worked(1);
              spark.showPublishedAppDialog(_appID);
            }).catchError((e) {
              monitor.worked(1);
              spark.showUploadedAppDialog(uploadedAppID);
            });
          }
        });
      });
    }).catchError((e) {
      spark.showErrorMessage('Error while publishing the application', e.toString());
    });
  }
}

// TODO: This does not need to extends SparkActionWithDialog - just dialog.
class GitAuthenticationDialog extends SparkActionWithDialog {
  Completer completer;
  static GitAuthenticationDialog _instance;
  bool _initialized = false;

  GitAuthenticationDialog(spark, dialogElement)
      : super(spark, "git-authentication", "Authenticate", dialogElement);

  void _invoke([Object context]) {
    if (!_initialized) {
      _dialog.element.querySelector(".cancel-button").onClick.listen((_) => _cancel());
      _initialized = true;
    }

    spark.setGitSettingsResetDoneVisible(false);
    _show();
  }

  void _commit() {
    final String username = (getElement('#gitUsername') as InputElement).value;
    final String password = (getElement('#gitPassword') as InputElement).value;
    final String encoded =
        JSON.encode({'username': username, 'password': password});
    spark.syncPrefs.setValue("git-auth-info", encoded).then((_) {
      completer.complete({'username': username, 'password': password});
      completer = null;
    });
  }

  void _cancel() {
    completer.completeError("cancelled");
    completer = null;
  }

  static Future<Map> request(Spark spark) {
    if (_instance == null) {
      _instance = new GitAuthenticationDialog(spark,
          spark.getDialogElement('#gitAuthenticationDialog'));
    }
    assert(_instance.completer == null);
    _instance.completer = new Completer();
    _instance.invoke();
    return _instance.completer.future;
  }
}

class ImportFileAction extends SparkAction implements ContextAction {
  ImportFileAction(Spark spark) : super(spark, "file-import", "Import File…");

  void _invoke([List<ws.Resource> resources]) {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.OPEN_FILE);
    chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
      chrome.ChromeFileEntry entry = res.entry;
      if (entry != null) {
        ws.Folder folder = resources.first;
        folder.importFileEntry(entry).catchError((e) {
          spark.showErrorMessage('Error while importing file', e);
        });
      }
    });
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleFolder(object);
}

class ImportFolderAction extends SparkAction implements ContextAction {
  ImportFolderAction(Spark spark) : super(spark, "folder-import", "Import Folder…");

  void _invoke([List<ws.Resource> resources]) {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.OPEN_DIRECTORY);
    chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
      chrome.DirectoryEntry entry = res.entry;
      if (entry != null) {
        ws.Folder folder = resources.first;
        folder.importDirectoryEntry(entry).catchError((e) {
          spark.showErrorMessage('Error while importing folder', e);
        });
      }
    });
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleFolder(object);
}

// Analytics code.

void _handleUncaughtException(error, [StackTrace stackTrace]) {
  // We don't log the error object itself because of PII concerns.
  final String errorDesc = error != null ? error.runtimeType.toString() : '';
  final String desc =
      '${errorDesc}\n${utils.minimizeStackTrace(stackTrace)}'.trim();

  _analyticsTracker.sendException(desc);

  window.console.error(error);
  if (stackTrace != null) {
    window.console.error(stackTrace.toString());
  }
}

bool get _isTrackingPermitted =>
    _analyticsTracker.service.getConfig().isTrackingPermitted();

set _isTrackingPermitted(bool value) =>
    _analyticsTracker.service.getConfig().setTrackingPermitted(value);
