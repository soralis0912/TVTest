# TVTest for macOS

復号済みのローカル録画再生および [MacBonDriver](https://github.com/soralis0912/MacBonDriver)（`.bundle`）によるライブ放送受信・録画に対応した macOS 版 TVTest です。
本体は AppKit アプリで、起動時に同梱の `TvtPlay.bundle` を読み込み、
LibISDB で TS/M2TS 内のサービス・番組情報・EPG・ARIB 字幕・放送局ロゴ・パケット統計をリアルタイム解析します。
TvtPlay が LibVLC を使ってローカル録画および MacBonDriver からのライブ TS ストリームをデコードし、再生制御・アスペクト比・インターレース解除・静止画キャプチャ・二カ国語（主／副音声）切替を提供します。
Wine や Rosetta は不要です。

## MacBonDriver によるライブ受信・録画

- `ドライバ → MacBonDriver (.bundle) を開く…`（`⇧⌘O`）から任意の MacBonDriver v1.0 `.bundle`（例: `MBD_SampleUSB.bundle`、`MBD_SQR100.bundle` 等）を読み込めます。
- `~/Library/Application Support/TVTest/BonDrivers`（または環境設定で指定したフォルダ / アプリ内 `PlugIns/BonDrivers`）に配置した `.bundle` は `ドライバ` メニューに自動列挙されます。
- `チャンネル` メニューからチューニング空間・物理チャンネルを選局でき、TSMF (`MacBonDriverTSMF`)・LNB 給電 (`MacBonDriverLNBControl`)・内蔵スマートカード状態確認 (`MacBonDriverSmartCard`)・ホットプラグ通知 (`MacBonDriverDelegate`) に対応しています。
- ライブ受信中に `⌘R`（`ファイル → 録画開始／停止`）で `LibISDB::ServiceSelectorFilter` 経由のライブ録画を行えます。

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

テストを実行するには以下を使用します（LibISDB ユニットテストおよび macOS 録画解析統合テストを実行します）。

```sh
make -C TVTest/macos test
```

## 主な機能（Windows 版 TVTest パリティ機能）

- **サイドパネル (`⌘L`)**: Windows 版 TVTest と同様のドッキングパネル（右／左配置切替可）を備え、4 つのタブを切り替えられます。
  - **情報**: サービス・NID/TSID・映像解像度・映像/音声種別・放送時刻 (TOT)・ビットレート・パケット/ドロップ/スクランブル統計・現在/次の番組。
  - **チャンネル**: 放送局ロゴ（CDT/SDTT から自動抽出・キャッシュ）付きサービス一覧。ダブルクリックでサービス切替。
  - **番組**: 選択中サービスの EPG スケジュール一覧と詳細表示。
  - **字幕**: ARIB 字幕のタイムスタンプ付きライブログ。再生位置に連動してハイライトされ、行をダブルクリックするとその時刻へシーク可能。検索・コピー・`.srt`/`.txt` 保存に対応。
- **OSD（オンスクリーン表示）**: サービス切替・音量変更・シーク・速度変更・キャプチャ保存時に映像上へ透過 HUD をフェード表示します。
- **映像制御 (`映像` メニュー)**:
  - **表示倍率**: 50% / 75% / 100% / 150% / 200%
  - **アスペクト比**: 自動 / 16:9 / 4:3 / 2.35:1
  - **パン＆スキャン（クロップ）**: なし / 16:9 / 4:3 / 16:10 / 2.35:1
  - **インターレース解除**: OFF / Blend / Bob / Linear / Yadif / Yadif 2x
  - **常に最前面表示 (`⌃⌘T`)**、**再生コントロール非表示 (`⌘B`)**、**フルスクリーン (`⌃⌘F`)**
- **音声・二カ国語制御 (`音声` メニュー)**:
  - 音声トラック切替（LibISDB の音声コンポーネント記述子付き）
  - **音声モード**: ステレオ / 主音声 (左) / 副音声 (右) / 反転ステレオ
- **ARIB 字幕オーバーレイ (`⌘T`)**: PES の PTS に同期した ARIB 8 色パレット・文字サイズ・クリア制御対応オーバーレイ。フォントサイズや背景不透明度を環境設定で調整可能。
- **番組表 / EPG (`⌘E`) & 番組検索 (`⌘F`)**:
  - **グリッド表示（タイムテーブル）**（ARIB ジャンル別カラー配色）と **リスト表示** の切替に対応。
  - `LibISDB::EPGDataFile` による `EPGData.dat` 自動保存・読み込みおよび JSON エクスポートに対応。
  - `⌘F` で全サービス横断のキーワード・ジャンル・サービス絞り込み検索が可能。
- **静止画キャプチャ & サービス別 TS 書き出し**:
  - `⌘S` で静止画キャプチャ保存（`%date%`, `%time%`, `%service-name%`, `%event-name%` 変数書式対応）、`⇧⌘C` でクリップボードへコピー。
  - `⇧⌘S` で `LibISDB::ServiceSelectorFilter` を用いた選択中サービス単独の TS 切り出し保存に対応。
- **ストリーム情報 (`⌥⌘I`)**: サービス・ES PID 構成および PID 別のパケット数・ドロップ数・スクランブル数の統計テーブルを表示。
- **環境設定 (`⌘,`)**: 保存先・ファイル名書式・OSD・最前面・パネル位置・デフォルト映像設定・字幕フォント・EPG キャッシュ管理を永続化。
