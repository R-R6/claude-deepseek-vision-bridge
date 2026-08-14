# Claude Code instructions

When a user provides an image path and the active model cannot accept images, run the platform-appropriate command:

```powershell
node .\src\vision.js <image-path> [question]
```

```sh
sh ./src/vision.sh <image-path> [question]
```

For images pasted directly into Claude Code, use the running local bridge. Do not store or print image base64 data or API keys. If the bridge is unavailable, check `http://127.0.0.1:15720/health` before changing model mappings.
