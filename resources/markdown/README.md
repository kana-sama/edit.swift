# Markdown rendering assets

Edit packages `assets.tar.gz` and `preview.html` in the app bundle. The regular Swift build uses the packaged assets. Run `bash resources/markdown/build` to regenerate the archive after changing the renderer, using Node.js and the pinned `package-lock.json`. The archive includes dependency notices and licenses.

`render.js` parses Markdown in JavaScriptCore with remark and renders sanitized HTML with rehype. The WebKit view loads KaTeX and Mermaid only for documents that use them. The native app resolves local assets and handles explicitly approved remote image URLs.
