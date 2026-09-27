#!/usr/bin/env node
// 零依赖静态服务器：服务 MoreJokerSlots/ 目录，让网页能 fetch state.dat（快照，内容是 JSON；扩展名避开 SMODS loader 的 .json 扫描）。
// （浏览器从 file:// fetch 本地文件会被 CORS 拦，必须有 http 服务器，见 NOTES §8）
//
// 用法:  node tools/serve.js  [端口]
// 然后浏览器打开 http://localhost:8666/

const http = require("http");
const fs   = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");           // mod 根目录
const PORT = parseInt(process.argv[2] || "8666", 10);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js":   "text/javascript; charset=utf-8",
  ".css":  "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

const server = http.createServer((req, res) => {
  let rel = decodeURIComponent(req.url.split("?")[0]);
  if (rel === "/") rel = "/web/index.html";

  // 防目录穿越：解析后必须仍在 ROOT 内
  const abs = path.join(ROOT, rel);
  if (!abs.startsWith(ROOT)) { res.writeHead(403); res.end("forbidden"); return; }

  fs.readFile(abs, (err, buf) => {
    if (err) {
      res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      res.end("404: " + rel);
      return;
    }
    const mime = MIME[path.extname(abs).toLowerCase()] || "application/octet-stream";
    // state.dat 禁缓存，保证网页每次拿到最新快照
    const headers = { "content-type": mime };
    if (abs.endsWith("state.dat")) headers["cache-control"] = "no-store";
    res.writeHead(200, headers);
    res.end(buf);
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`MoreJokerSlots 预测面板`);
  console.log(`  服务目录: ${ROOT}`);
  console.log(`  打开浏览器: http://localhost:${PORT}/`);
  console.log(`  (Ctrl+C 停止)`);
});
