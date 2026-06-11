# cloudlibrary

#### Plugin Introduction

KOReader plugin - Cloud Library, synchronize books and metadata (book annotations, reading progress, etc.) between devices.

#### Synchronization Principle

1. This plugin directly operates on the device's original metadata files. By uploading/downloading/updating metadata files, it achieves one-time synchronization of book information such as annotations and reading progress.
2. It also supports batch upload/download of books themselves, enabling complete library synchronization.

#### Installation

After downloading and extracting, directly place the `cloudlibrary.koplugin` folder into the `koreader\plugins` directory on your device.

#### Instructions
 ![Cloud Library - Menu](picture/云端书库-菜单.png)

【Prerequisites】
1. In the file browser interface, select 「Menu」 → 「Tools」 → 「Cloud Storage」 to add a cloud storage account.
2. Plugin operation: 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」 → Select a cloud directory to store book metadata files, book files, and sync record files.
   - The cloud directory for books defaults to the metadata cloud directory, and an independent cloud directory can also be optionally selected.
   - Different devices must use the **same cloud directory**, otherwise they cannot share.
3. The local book metadata folder settings on different devices should be kept consistent ("Settings" → "Documents" → "Book Metadata Folder"). Usually, they are consistent by default, but if this setting is changed on one device, the other devices should also be changed accordingly; otherwise, you may be prompted that the local metadata file cannot be found.

【Cloud Naming Rules】
- Metadata: Optional filename / Use book title (default) / Use title_author
- Books: Optional filename / Use book title (default) / Use title_author
- Note: The cloud naming rules should be consistent across different devices.

【Metadata Upload Backup】
Directly upload the local metadata file (`.lua` format) corresponding to the local book to the cloud. If a file with the same name already exists in the cloud, it will be directly overwritten.
![Cloud Library - Batch Upload Metadata](picture/云端书库-批量上传元数据.png)

【Metadata Download Update】
- **Overwrite Mode**: Cloud files directly overwrite local files. You can choose whether to keep local document settings via 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」.
![Cloud Library - Batch Download Metadata - Overwrite](picture/云端书库-批量下载元数据-覆盖更新.png)

- **Merge Mode**: Based on local data, merge unique and updated information from the cloud.
   - **Annotations**: Keep all annotations from both local and cloud (including highlights, underlines, bookmarks, notes, etc.) and merge, update, deduplicate, and sort them.
   - **Reading Status**: Take the higher priority: Finished Reading > Reading > Unread.
   - **Reading Progress**: Take the further value (farthest progress).
   - **Reading Statistics**: Number of highlights and notes are automatically calculated based on the merged results.
   - **Document Settings**: Keep local settings.
![Cloud Library - Batch Download Metadata - Merge](picture/云端书库-批量下载元数据-合并更新.png)

【Metadata Download Mode (Manual)】
Used for quickly switching between Overwrite/Merge modes (does not affect the automatic download update mode).

【Book Synchronization Instructions】
- If a file with the same name already exists in the cloud during upload, it will be directly overwritten.
- If a file with the same name already exists locally during download, it will be skipped (details can be viewed in the sync log). If you really need to download it, please delete/rename the local file first.
![Cloud Library - Batch Download Books](picture/云端书库-批量下载书籍.png)
![Cloud Library - Batch Download Books - Search](picture/云端书库-批量下载书籍-搜索.png)
![Cloud Library - Batch Download Books - Select](picture/云端书库-批量下载书籍-勾选.png)
![Cloud Library - Batch Download Books - Select 2](picture/云端书库-批量下载书籍-勾选2.png)
![Cloud Library - Batch Download Books - Confirm](picture/云端书库-批量下载书籍-确认.png)

【Batch Synchronization Method】
1. **Manual operation**: In the file manager, enter selection mode → check the books to sync → tap 「Menu」→「Tools」→「Cloud Library」→「Metadata Sync/Book Sync」
2. **Gesture shortcut operation**: After setting up a gesture shortcut, you can enter selection mode directly via gesture, check the books, then execute upload/download again via gesture

【Automatic Sync Settings (Metadata Only)】 
*Only applies to the currently open book*
1. Disabled by default. Check the specific options below to enable the corresponding mode.
2. **Auto upload backup**: Automatically upload metadata to overwrite the cloud when editing annotations, closing a book, or when the device goes to sleep. (Multiple triggers can be enabled at the same time, but not recommended. It is advisable to choose either closing the book or device sleep for auto backup.)
3. **Auto download update**: Automatically download metadata from the cloud to update locally when opening a book (overwrite/merge modes available)
- **Notes:**
  - Auto sync only syncs the metadata of the book at the triggered moment, not all books continuously.  
  Example: If 「Auto upload on close」 is enabled, no matter which book or where it is located, whenever a book is closed, the device will automatically upload that book's metadata, overwriting the same-named metadata file in the cloud directory.
  - When using this plugin for the first time, please **manually batch upload** the local metadata from your current device to the cloud before enabling auto sync.
  - To prevent accidental data overwrites between different devices when auto sync is enabled, it is recommended to choose **Merge Update** mode.
  - Make sure your device is connected to the internet, otherwise auto sync will not work.

【Additional JSON Backup】
When enabled, an additional JSON file converted from the original metadata file will be uploaded alongside the original metadata file. The JSON format is not a standard file for KOReader book metadata synchronization across different devices, but is intended for users who need to further organize their KOReader annotations. Enable as needed.

【Sync Log】
1. A sync log is generated for each sync operation, which can be used to troubleshoot sync failures.
2. Enable 「Record Cloud Sync」, and sync logs will be automatically synchronized with the cloud, allowing you to view sync logs from different devices.(To minimize performance impact, please enable it only when needed.)
3. You can clear local and cloud sync logs via the "Clear" button in the sync log and 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」 → Clear Cloud Sync Log respectively.
![Cloud Library - Sync Log - Batch Download Metadata](picture/云端书库-同步记录-批量下载元数据.png)
**Note:** Because this plugin directly manipulates the device's existing metadata files, if there is no local metadata file on the device (e.g., for a book that has never been opened before), it will prompt a sync failure indicating that the local metadata file was not found. In this case, simply open the book first and then perform the sync operation.

【Gesture Shortcuts】
- Enter 「Settings」 → 「Gestures」 → 「Gesture Manager」 from the reading interface and file browser interface respectively. Select a gesture and check the corresponding Cloud Library menu items in the Reader and File Manager.
- Combined with the Metadata Download Mode setting, you can achieve one-gesture download / batch download (smart mode).
- **Worry-Free Sync Mode**: One gesture to enable/disable automatic metadata sync (auto upload backup when closing a book / device sleeping; auto download and merge update when opening a book).

![Cloud Library - Gesture Shortcut - File Manager](picture/云端书库-快捷手势-文件管理器.png)
![Cloud Library - Gesture Shortcut - Reader](picture/云端书库-快捷手势-阅读器.png)
![Cloud Library - Quick Settings](picture/云端书库-快捷设置.png)
![Cloud Library - ZenUI Quick Settings](picture/云端书库-zenui快捷设置.png)
![Cloud Library - ZenUI Quick Settings 2](picture/云端书库-zenui快捷设置2.png)

#### Changelog
cloudlibrary (renamed) adds new features and fixes bugs based on the v0.22 version of MetedataSync (previous name) from Xiaohongshu:

1.  Added book sync functionality, allowing batch upload, download, or deletion of cloud books (v1.0)
2.  Added gesture shortcuts, allowing quick actions and quick settings via gestures (v1.0)
3.  Fixed potential state confusion in file browser selection mode when using gesture shortcuts (v1.0)
4.  Fixed crash issue with PDF documents during merge update (v1.0)
5.  Fixed issue where some annotations might lose rendering during merge update (v1.0)
6.  Optimized note update issues during merge update (v1.0)
7.  Added function to clear cloud sync logs (v1.0)
8.  Fixed potential format confusion issue when enabling Record Cloud Sync for sync logs (v1.0)
9.  Removed mutual exclusion restriction for auto upload and auto download, allowing both to be enabled simultaneously (v1.0)
10. Added online update feature (v1.0)
11. Changed overwrite update from complete overwrite to optional overwrite, allowing choice to keep local document settings (v1.0)
12. Fixed online update crash issue on Android (v1.1)
13. Fixed the issue where synchronization failed when opening a book for the first time (v1.2)
14. Added support for setting an independent cloud directory for books (separate from metadata cloud directory) (v1.2)
15. Added pre-flight checks for network and configuration (v1.3)
16. Added Worry-Free Sync Mode quick toggle for metadata (v1.3)
17. Fixed path concatenation issues for sync logs, metadata and temporary folders (v1.3)
18. Removed debug logs (v1.3)
19. Added English support: Menu changed to English with Chinese translation (v1.4)
20. Progress bar for upload/download: Upload progress by book count, download progress by bytes (v1.4)
21. Manual and auto sync download modes are no longer shared: Prevents temporary switching of download mode in manual sync from affecting automated sync tasks (v1.4)
22. Optimized update channel: Added three update sources options - GitHub (Latest), GitHub (Pre-release), Gitee (Latest)  (v1.4)
23. Added changelog.lua to track version history (v1.4.1)
24. Optimize plugin module loading path and fix naming conflict with other plugins (v1.4.1)

#### Contributing

1.  Fork this repository
2.  Create a new Feat_xxx branch
3.  Commit your code
4.  Create a new Pull Request

#### Project Repository

- Gitee : https://gitee.com/gytwo/cloudlibrary.koplugin
- GitHub: https://github.com/gytwo/cloudlibrary.koplugin