# cloudlibrary

#### Plugin Introduction

KOReader plugin - Cloud Library, synchronize books and metadata (book annotations, reading progress, etc.) between devices.

#### Synchronization Principle

1. This plugin directly operates on the device's original metadata files. By uploading/downloading/updating metadata files, it achieves one-time synchronization of book information such as annotations and reading progress.
2. It also supports batch upload/download of books themselves, enabling complete library synchronization.

#### Installation

After downloading and extracting, directly place the `cloudlibrary.koplugin` folder into the `koreader\plugins` directory on your device.

#### Instructions

【Prerequisites】
1. In the file browser interface, select 「Menu」 → 「Tools」 → 「Cloud Storage」 to add a cloud storage account.
2. Plugin operation: 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」 → Select a cloud directory to store book metadata files, book files, and sync record files.
   - Different devices must use the **same cloud directory**, otherwise they cannot share.
3. The local metadata storage location should be consistent across different devices (「Settings」 → 「Document」 → 「Book Metadata Folder」). The default is usually consistent, but if one device changes this setting, other devices should change accordingly; otherwise, an error may occur indicating that the local metadata file cannot be found.

【Cloud Naming Rules】
- Metadata: Optional filename / Use book title (default) / Use title_author
- Books: Optional filename / Use book title (default) / Use title_author
- Note: The cloud naming rules should be consistent across different devices.

【Metadata Upload Backup】
Directly upload the local metadata file (`.lua` format) corresponding to the local book to the cloud. If a file with the same name already exists in the cloud, it will be directly overwritten.

【Metadata Download Update】
- **Overwrite Mode**: Cloud files directly overwrite local files. You can choose whether to keep local document settings via 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」.
- **Merge Mode**: Based on local data, merge unique and updated information from the cloud.
   - **Annotations**: Keep all annotations from both local and cloud (including highlights, underlines, bookmarks, notes, etc.) and merge, update, deduplicate, and sort them.
   - **Reading Status**: Take the higher priority: Finished Reading > Reading > Unread.
   - **Reading Progress**: Take the further value (farthest progress).
   - **Reading Statistics**: Number of highlights and notes are automatically calculated based on the merged results.
   - **Document Settings**: Keep local settings.

【Metadata Download Mode (Manual)】
Used for quickly switching between Overwrite/Merge modes (does not affect the automatic download update mode).

【Book Synchronization Instructions】
- If a file with the same name already exists in the cloud during upload, it will be directly overwritten.
- If a file with the same name already exists locally during download, it will be skipped (details can be viewed in the sync log). If you really need to download it, please delete/rename the local file first.

【Batch Synchronization Method】
1. Long-press on a file in the file browser to enter selection mode.
2. Check the books to synchronize.
3. Select 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Metadata Sync/Book Sync」

【Automatic Sync Settings (Metadata Only)】 – Only for the currently open single book
1. Disabled by default. Check the specific options below to enable the corresponding mode automatically.
2. **Auto Upload Backup**: Automatically upload metadata to overwrite the cloud when editing annotations, closing a book, or when the device goes to sleep. (You can enable multiple triggers simultaneously, but not recommended. It is recommended to choose either closing the book or device sleep for auto backup.)
3. **Auto Download Update**: Automatically download metadata from the cloud to update locally when opening a book (Overwrite/Merge modes).

- **Notes:**
  - Enabling auto upload will cause the cloud metadata file to be completely overwritten by the current device's metadata file. Please use with caution.
  - Enabling auto download will cause the current device's metadata file to be completely overwritten or merged by the cloud metadata file. Please use with caution.
  - When enabling auto sync, to prevent accidental overwriting of data from different devices, it is recommended to choose **Merge Update Mode**.

【Additional JSON Backup】
When enabled, an additional JSON file converted from the original metadata file will be uploaded alongside the original metadata file. The JSON format is not a standard file for KOReader book metadata synchronization across different devices, but is intended for users who need to further organize their KOReader annotations. Enable as needed.

【Sync Log】
1. A sync log is generated for each sync operation, which can be used to troubleshoot sync failures.
2. Enable 「Record Cloud Sync」, and sync logs will be automatically synchronized with the cloud, allowing you to view sync logs from different devices.
3. You can clear local and cloud sync logs via the "Clear" button in the sync log and 「Menu」 → 「Tools」 → 「Cloud Library」 → 「Settings」 → Clear Cloud Sync Log respectively.

**Note:** Because this plugin directly operates on the device's original metadata files, if there is no local metadata file (e.g., a book that has never been opened, or a newly opened book that hasn't generated a metadata file yet), the sync will fail with an error indicating that the local metadata file was not found. In this case, simply reopen the book and then perform the sync operation.

【Gesture Shortcuts】
- Enter 「Settings」 → 「Gestures」 → 「Gesture Manager」 from the reading interface and file browser interface respectively. Select a gesture and check the corresponding Cloud Library menu items in the Reader and File Manager.
- Combined with the Metadata Download Mode setting, you can achieve one-gesture download/batch download (smart mode).

#### Update Notes
cloudlibrary (renamed) adds new features and fixes bugs based on the v0.22 version of MetedataSync (previous name) from Xiaohongshu:

1.  Added book sync functionality, allowing batch upload or download of cloud books (v1.0)
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

ps: The online update feature has been tested and causes crashes on Android devices. However, the new file will still be automatically downloaded to the `koreader\plugins` path. Please find the plugin archive in that path, extract it, and overwrite the old plugin files.

#### Contributing

1.  Fork this repository
2.  Create a new Feat_xxx branch
3.  Commit your code
4.  Create a new Pull Request

#### Highlights

1.  Use `Readme_XXX.md` to support different languages, e.g., Readme_en.md, Readme_zh.md
2.  Gitee official blog [blog.gitee.com](https://blog.gitee.com)
3.  You can visit [https://gitee.com/explore](https://gitee.com/explore) to learn about excellent open-source projects on Gitee
4.  [GVP](https://gitee.com/gvp) stands for Gitee Most Valuable Open Source Project, which are outstanding open-source projects comprehensively evaluated
5.  Gitee official user manual [https://gitee.com/help](https://gitee.com/help)
6.  Gitee Cover Character is a column showcasing Gitee member风采 [https://gitee.com/gitee-stars/](https://gitee.com/gitee-stars/)