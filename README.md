# Levistica

動画・資料調査・SNSに使う、個人用macOSブラウザです。メモリ使用量を最優先に、速さ、安全性、Macアプリとしての扱いやすさと、好みに変えられる外枠UIを目指します。

正式アプリでURL入力、ページ表示、戻る／進む、終了と再起動までを実装し、Debug／Releaseのビルドと基本操作を確認しました。単体試験13件とUI試験5件が通っています。動画の全画面表示と復帰にも対応しました。YouTubeの公開動画、Xの公開トップ、Discordのログイン画面を確認しました。本人のログインと同条件のメモリ比較は未確認で、日常利用の受入前です。推奨方式はSwiftUI＋AppKit＋システムWebKitのWKWebViewで、Chromeより省メモリになるかは今後実測します。現在はM1の認証・互換性確認とメモリ比較を進める段階です。

## 文書の読み方

| 文書 | 内容 |
|---|---|
| [PRODUCT_SPEC.md](PRODUCT_SPEC.md) | 使う場面、v1の範囲、通常・失敗時の挙動、受入条件 |
| [PLAN.md](PLAN.md) | 方式と技術設計、検証、設計期間、M0〜M5、未解決事項とスキルの導入時期 |
| [AGENTS.md](AGENTS.md) | Codexの担当、変更・検証・スキル参照・文章のルール |

ユーザーがPM兼利用者として優先順位と受入を判断し、Codexが技術調査・設計・実装・検証を担当します。初期設計の目安は1〜3作業日とし、2026-10-20に初版とGitHub上の基準版を記録しました。以後の環境・設計の修正はPRへまとめます。実機での認証・性能検証はM1以降に行い、PLAN.mdに沿った実装開始は承認済みです。

## 開発の進め方

初回に設計の基準版をmainへ記録します。その後は、一つの使い方や問題ごとにブランチを作り、小さな変更と必要な検証をPRへまとめます。PRには利用者から見た挙動、確認したこと、未確認のことを残し、合意した受入条件で完了を判断します。必要な検証を終えた通常のPRはCodexがmainへ統合します。製品条件の変更や費用など、利用者の判断が必要な場合は相談します。

最初に、正式なLevisticaで「起動→URL入力→ページ表示→戻る/進む→終了」をつなぎ、基本操作を確認しました。同じアプリをM5の常用版まで育てます。工程の詳細と環境の不足はPLAN.mdで管理し、Issuesや管理文書を先に大量生成しません。

## スキルと個人データ

スキルの本文と参照は `skills/`、取得元・版・ハッシュは [skills/SOURCES.json](skills/SOURCES.json) にあります。Codexは作業に合うスキルを自ら参照し、工程で必要になった追加スキルはPLAN.mdの条件に従って導入します。ユーザーが毎回指定する必要はありません。yomiyasuの版確認・更新は行わず、最後に手元のリンターを1回使います。

imozuru原版は他プロジェクトへの絶対パスリンクを外し、このリポジトリ内へコピーしました。元の設置先は変更していません。新しい環境での自動認識には、PLAN.mdに記載した `.agents/skills` の相対リンクを設定し、Codexの一覧で確認します。

ブラウザのプロファイル、Cookie、認証情報、閲覧履歴、私的な試験資料・計測ログはGitへ入れません。`.local/`、`research/`、ビルド成果物は除外します。第三者スキルの条件は各出典・ライセンスに従い、本体の公開やライセンスの選択は別途判断します。

## 開発中の起動と試験

Xcodeは `/Applications/Xcode.app` を入口スクリプト内の `DEVELOPER_DIR` で選びます。全体のxcode-select設定は変更しません。ライセンス同意と `xcodebuild -runFirstLaunch` の成功が前提です。

```sh
./script/build_and_run.sh           # Debugをビルドして起動
CONFIGURATION=Release ./script/build_and_run.sh --verify
./script/test.sh --unit             # Swift Testing
./script/test.sh --ui               # 隔離データとloopbackページでXCUITest
```

Runボタンは同じ `script/build_and_run.sh` を呼びます。アプリと検証ログはGit対象外の `.local/` に置きます。テストは通常のログインデータを使いません。URL欄はHTTP/HTTPS、ホスト名、検索語を扱い、検索は入力確定後にDuckDuckGoへ送信します。M1初版にはタブ保存、認証ポップアップ、ダウンロード、権限許可、入力保護がまだ揃っていないため、日常利用の受入前です。

このMacではルート直下の `research-reference` から調査資料を参照できます。元資料は変更しません。このリンクは他プロジェクトへの絶対パスを指すためGit対象外で、別のMacへは引き継がれません。

GitHub Actionsはmacos-26／Xcode 26.6でReleaseビルド、単体試験、計測パーサーの試験を実行します。UI試験は実機で確認し、CIの合格と区別します。ローカルのXcode 27.1とCIの版は別に記録し、環境更新を製品仕様の変更と混同しません。

メモリの取得経路は次で確認できます。Releaseを起動し、表示状態を整えてから実行します。`--loaded-pages` は空画面なら0、1ページを表示中なら1です。

```sh
python3 script/measure-memory.py --label one-page --loaded-pages 1 --samples 3 --interval 5
```

このツールはアプリのPIDドメインで実行中のXPCサービスを照合し、前後でPID・開始時刻・実行パスが変わった値を集計から外します。取得失敗を0にせず、`phys_footprint` を記録します。合計は共有メモリが重複し得るため専有RAMとは呼びません。閲覧先のURL、Cookie、フォーム値、launchctlの環境値を記録せず、結果は `.local/artifacts/memory/` に置きます。短い連続測定だけでは、Chromeとの比較や受入目標は決めません。

固定fixtureのloopback URLと表示領域は比較条件として記録します。固定ページの比較には、次のサーバーを別のターミナルで起動します。表示されたローカルURLを使い、測定後はCtrl+Cで終了します。

```sh
python3 script/memory-fixture.py .local/artifacts/comparison/fixture-state.json
```

Levisticaを隔離データで起動する場合は、`LEVISTICA_EPHEMERAL=1 CONFIGURATION=Release ./script/build_and_run.sh` を使います。この起動ではログイン情報を終了後に残しません。通常起動の保存データは使いません。

比較用Chromeは `python3 script/comparison-chrome.py start --url 表示されたローカルURL` で、新しいプロジェクト内プロファイルに起動します。返されたprofileを指定して、計測コマンドに `--browser chrome --chrome-profile プロファイルの絶対パス` を加えます。両ブラウザとも `--ready-file .local/artifacts/comparison/fixture-state.json` を加えると、ページの準備完了から60秒待って測ります。一度に測るのは片方だけにし、その間は別ページを読み込まないでください。

Chromeの試行後は `python3 script/comparison-chrome.py stop --profile プロファイルの絶対パス` で、作成済みの比較用インスタンスだけを終了できます。専用プロファイル、実行パス、PID、開始時刻を照合し、合わなければ終了しません。通常利用のChromeは対象外です。起動用のフラグはChromiumの[ユーザーデータディレクトリの公式資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)に従っています。
