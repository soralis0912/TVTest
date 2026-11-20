# TVTest for macOS

復号済みのローカル録画を TVTest のウィンドウ内で再生する macOS 版です。
本体は AppKit アプリで、起動時に同梱の `TvtPlay.bundle` を読み込みます。
TvtPlay が LibVLC を使って映像・音声をデコードし、再生・一時停止・停止・シークを提供します。
Wine、Rosetta、チューナー用ドライバは不要です。

## ビルド

macOS 14 以降と CMake 3.20 以降、Xcode または Xcode Command Line Tools が必要です。
[VideoLAN の macOS 用 VLC 3](https://www.videolan.org/vlc/download-macosx.html) を
`/Applications/VLC.app` に置いてください。VLC 本体を起動する必要はありませんが、
ビルド後もライブラリとコーデックを参照するため、同じ場所に残してください。

同じ親ディレクトリに両フォークをチェックアウトします。

```sh
git clone --recurse-submodules --branch macos https://github.com/soralis0912/TVTest.git
git clone --branch macos https://github.com/soralis0912/TvtPlay.git
make -C TVTest/macos
open TVTest/macos/build/TVTest.app
```

すでに両方のフォークがある場合は、各リポジトリの `macos` ブランチを使い、TVTest で `git submodule sync` と
`git submodule update --init` を実行してからビルドします。
別の場所に配置した場合は、`make` に `TVTPLAY_DIR=/path/to/TvtPlay/macos/plugin` や
`VLC_APP=/path/to/VLC.app` を指定できます。

## 開く

TVTest で ⌘O を押して `.m2ts`、`.ts`、`.m2t`、`.mts` を選びます。
再生中に **⌘I** を押すと、LibISDB が録画の先頭 32 MiB を解析し、
サービス名と、放送波に含まれる現在・次の番組情報を表示します。
表示内容は録画の先頭付近の放送情報に基づきます。

ターミナルから直接開くこともできます。

```sh
open -a "$PWD/TVTest/macos/build/TVTest.app" "/path/to/録画.m2ts"
```

macOS 版の対象はファイル再生です。Windows 版の Win32・DirectShow 本体と
`.tvtp` プラグインは macOS 版から独立しています。放送受信、B-CAS 復号、
番組表、ARIB 字幕表示は macOS 版の実装範囲外です。

AAC が PMT 上で私用データとして記録された M2TS では、LibVLC が音声トラックを認識しない場合があります。
