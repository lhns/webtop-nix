# Selkies: a separate upload directory

Draft for upstream; not posted. Patch: `pkgs/selkies/upload-path.patch` (against 2.1.0).

`file_manager_path` is both the directory the file browser serves and where uploads land. Serving a
wide root (the home directory) while keeping uploads in one inbox needs two directories.

New setting `upload_path` (`SELKIES_UPLOAD_PATH`, default empty). When set, `POST /api/upload` and
the websockets/WebRTC upload paths write under it, with the same traversal and realpath checks
against that directory. When empty, uploads go to `file_manager_path` as before, so existing
deployments are unchanged. Downloads and `/api/files/` keep using `file_manager_path`.
