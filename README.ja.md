<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Audio Output Scheduler アイコン">
</p>

<h1 align="center">Audio Output Scheduler</h1>

<p align="center">
  Mac の音声出力先を、決めた時刻に自動で切り替えるアプリ。<br>
  再生中なら音が止まるまで待ってから切り替えます。
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="docs/SPEC.md">Specification（英語）</a>
</p>

---

![メイン画面](docs/images/main-window.png)

## できること

- **時刻で切り替え** — 出力先と時刻を指定。スケジュールはいくつでも追加できます。
- **曜日ごとのオン／オフ** — スケジュールごとに日〜土を個別に設定（「毎日／平日／週末」の一括ボタン付き）。
- **再生中は待つ** — 指定時刻に音が鳴っていたら、止まってから 3 秒後に切り替えます。
- **無視するアプリ** — DAW などは無音でも出力を開いたままにするので、無視リストに入れて判定から外せます。
  GarageBand・Logic Pro・MainStage・Cubase・Ableton Live は最初から無視。任意のアプリも追加できます。
- **通知** — 切り替えたとき（または切り替えられなかったとき）にバナーでお知らせ。
- **機器の種類を表示** — 内蔵スピーカー、外部モニター、オーディオインターフェイス、仮想出力、
  Bluetooth、AirPlay、複数出力装置をアイコンで区別。
- **スピンボタンで時刻入力** — 時と分を別々のスピンボタンで（23→00 のように一周）。分のプリセットボタン付き。
- **スリープ明けにも対応** — 指定時刻にスリープしていたら、起きたときに切り替えます。
- **軽量なネイティブアプリ** — SwiftUI + Core Audio のみ、外部ライブラリなし。メニューバー常駐もなし。
  小さな補助プログラムが指定時刻にだけ動きます。

## 動作環境

- macOS 14 Sonoma 以降（macOS 26 Tahoe / Apple Silicon で開発・確認）
- ビルドに Xcode Command Line Tools（`xcode-select --install`）

## インストール

今のところビルド済みの配布はないので、ソースからビルドします。

```sh
git clone https://github.com/chibik1/AudioOutputScheduler.git
cd AudioOutputScheduler
./build.sh --install
open "/Applications/Audio Output Scheduler.app"
```

`./build.sh` だけなら `./build/` にビルドするだけでインストールはしません。アプリはアドホック署名なので、自分の Mac で使う分には問題ありません。

インストール後に一度アプリを開いてください。バックグラウンドの仕組みが登録され、通知の許可を求められます。

## 使い方

1. **Add Schedule** をクリック
2. 左の一覧から出力先を選ぶ（選んだ機器はアイコンと種類付きで右側に表示されます）
3. **Hour** と **Minute** のスピンボタンで時刻を設定（`:00 :15 :30 :45` のプリセットも使えます）
4. 曜日を選んで **Save**

メイン画面では、各行の曜日ボタンを直接オン／オフしたり、編集（鉛筆アイコンかダブルクリック）・削除ができます。変更はすぐ反映され、アプリを開いたままにしておく必要はありません。

| 設定 | 内容 |
| --- | --- |
| **Wait until audio stops playing** | 今の出力先が使用中なら切り替えを保留し、静かになって 3 秒後に切り替えます。 |
| **Ignore these apps…** | 出力を開いていても「再生中」とみなさないアプリ。**Add App…** で任意のアプリを追加。 |
| **Show a notification when the output switches** | 切り替えるたびにバナーを表示します。 |

## しくみ

スケジュールは JSON ファイルに保存され、ユーザー単位の `launchd` ジョブが各時刻に起動します。起動されるとアプリ内の小さな補助プログラムが、いま有効なスケジュールを判断し、Core Audio のプロセス単位の情報で今の出力先が再生中かを確認、必要なら待ってから出力先を切り替えて通知を出します。詳しくは **[docs/SPEC.md](docs/SPEC.md)**（英語）を参照してください。

## うまくいかないとき

**通知センターには入るのにバナーが出ない**
macOS はディスプレイのミラーリング・共有中にバナーを止めます。iPad をモニターにするアプリなどの仮想ディスプレイもこれに当たることがあります。
「システム設定 → 通知 → ディスプレイのミラーリング中または共有中に通知を許可」をオンにしてください。集中モードがオンになっていないかも確認を。

**あるアプリを開いていると切り替わらない**
そのアプリが出力を開いたままにしている可能性があります。無視リストで緑の *Using audio now* が付いているアプリのうち、対象にしたくないものの **Ignore** にチェックを入れてください（ブラウザはタブで音が鳴っているあいだ「再生中」になります）。

**「Couldn't switch sound output — … is not connected」と出る**
指定時刻に出力先の機器がつながっていませんでした。その回はスキップされます。

ログは `/tmp/audio-switch.log` に出力されます。

## アンインストール

```sh
launchctl bootout gui/$(id -u)/io.github.chibik1.audiooutputscheduler
rm ~/Library/LaunchAgents/io.github.chibik1.audiooutputscheduler.plist
rm -rf "/Applications/Audio Output Scheduler.app"
rm -rf ~/Library/Application\ Support/AudioOutputScheduler
```

## ライセンス

[MIT](LICENSE) © 2026 chibik1
