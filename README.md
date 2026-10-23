# Levistica

動画・資料調査・SNSに使う、個人用macOSブラウザです。メモリ使用量を最優先に、速さ、安全性、Macアプリとしての扱いやすさと、好みに変えられる外枠UIを目指します。

正式アプリで基本の閲覧、複数タブ、タブの検索・並べ替え・閉じたタブの再読込、ページ内検索、ズーム、終了後のタブ一覧の復元を実装しています。空タブや復元した未選択タブにはWebViewを作らず、選択したページから読み込みます。入力中のタブを切り替えても同じWebViewを保ちます。閉じたタブや終了前のフォーム入力は復元しません。

2026-10-21、全画面表示でページが小さいまま残る不具合を修正しました。従来の試験は全画面状態だけを確認して見逃していたため、画面を満たす寸法と解除後の復帰も検査し、fixtureの表示を画像で確認しています。その後、隔離データのReleaseでYouTube公開動画の全画面表示とEscapeによる復帰を確認しました。

推奨方式はSwiftUI＋AppKit＋システムWebKitのWKWebViewです。主要サイトの互換性とメモリ比較は継続中で、日常利用の受入前です。Discordは本人操作で通常画面まで進めましたが、通話操作時に非対応ブラウザ警告が出ています。マイク・カメラの許可もまだ実装していません。

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

Allocations等の診断は、承認済みの専用ビルドを使います。`CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 LEVISTICA_PROFILE=1 ./script/build_and_run.sh --verify` で、通常版と異なるbundle ID・生成先に起動します。デバッガー接続を許す権限を含むため配布せず、通常のメモリ比較にも使いません。投入上限と操作条件はPLAN.mdの個別診断計画に従います。

ビルドと試験の入口は、Python 3で実行パス・process名・所有者・bundle IDを照合します。不一致なら自動停止せずに中断します。診断用の前後には `python3 script/check-app-processes.py --only Profile` を実行し、通常版が混在していないことを確認してください。

CUAを使わない診断操作は `./script/test.sh --profile-ui` で実行します。専用Profileを正式入口から起動し、XCTestで合成5文書を2回休眠・再開させます。通常試験ではskip扱いです。メモリの計測器は接続せず、通常のRAM比較にも使いません。試験本体は180秒以内で、結果とfixtureの読込回数を `.local/artifacts/tests.*/` に残します。

`LEVISTICA_MALLOC_STACKS=1 ./script/test.sh --profile-ui` は、診断用だけに存続中の割当スタックを記録するための指定です。固定4時点のvmmapと8MiB以上の割当の呼出木を、トークンで認証するloopback経路から取得します。結果はローカル専用です。通常版での指定は拒否し、通常のRAM比較には使いません。

Runボタンは同じ `script/build_and_run.sh` を呼びます。アプリと検証ログはGit対象外の `.local/` に置きます。テストは通常のログインデータを使いません。UI試験は画面を操作し、全画面への切替も行います。全画面の状態・寸法・解除後の復帰を検査し、表示の修正時には保存画像も確認します。URL欄はHTTP/HTTPS、ホスト名、検索語を扱い、検索は入力確定後にDuckDuckGoへ送信します。ダウンロードとサイトの添付用ファイル選択を追加しました。入力操作を検知したタブでは、タブを閉じるときとアプリ終了時に確認を出します。サイトの権限許可や送信中の添付の保護はまだ揃っておらず、日常利用の受入前です。認証用の別タブを作る経路は追加しましたが、実サービスでの認証の成立は確認が残っています。

このMacではルート直下の `research-reference` から調査資料を参照できます。元資料は変更しません。このリンクは他プロジェクトへの絶対パスを指すためGit対象外で、別のMacへは引き継がれません。

GitHub Actionsはmacos-26／Xcode 26.6で通常Releaseと診断用のビルド、単体試験、計測ツールの試験を実行します。UI試験は実機で確認し、CIの合格と区別します。ローカルのXcode 27.1とCIの版は別に記録し、環境更新を製品仕様の変更と混同しません。

メモリの取得経路は次で確認できます。Releaseを起動し、表示状態を整えてから実行します。`--loaded-pages` は読み込み済みのページ数です。タブ一覧の総数も `--total-tabs` で指定し、未読込タブと分けて記録します。

```sh
python3 script/measure-memory.py --label one-page --loaded-pages 1 --samples 3 --interval 5
```

このツールはアプリのPIDドメインで実行中のXPCサービスを照合し、前後でPID・開始時刻・実行パスが変わった値を集計から外します。取得失敗を0にせず、`phys_footprint` を記録します。合計は共有メモリが重複し得るため専有RAMとは呼びません。閲覧先のURL、Cookie、フォーム値、launchctlの環境値を記録せず、結果は `.local/artifacts/memory/` に置きます。短い連続測定だけでは、Chromeとの比較や受入目標は決めません。

固定fixtureのloopback URLと表示領域は比較条件として記録します。固定ページの比較には、次のサーバーを別のターミナルで起動します。表示されたローカルURLを使い、測定後はCtrl+Cで終了します。

```sh
python3 script/memory-fixture.py .local/artifacts/comparison/fixture-state.json
```

Levisticaを隔離データで起動する場合は、`LEVISTICA_EPHEMERAL=1 CONFIGURATION=Release ./script/build_and_run.sh` を使います。この起動ではログイン情報を終了後に残しません。通常起動の保存データは使いません。

比較用Chromeは `python3 script/comparison-chrome.py start --url 表示されたローカルURL` で、新しいプロジェクト内プロファイルに起動します。返されたprofileを指定して、計測コマンドに `--browser chrome --chrome-profile プロファイルの絶対パス` を加えます。両ブラウザとも `--ready-file .local/artifacts/comparison/fixture-state.json` を加えると、ページの準備完了から60秒待って測ります。`--samples 1 --ready-delay 60`と、同じ起動のまま`--samples 1 --ready-delay 120`を順に使うと、表示後の時間をそろえて比較できます。実際の開始・終了時刻は結果へ残ります。比較用Chromeの`--width`と`--height`はウィンドウ寸法なので、fixtureが返す表示領域のwidth・height・DPRも照合してください。一度に測るのは片方だけにし、その間は別ページを読み込まないでください。

Chromeの試行後は `python3 script/comparison-chrome.py stop --profile プロファイルの絶対パス` で、作成済みの比較用インスタンスだけを終了できます。専用プロファイル、実行パス、PID、開始時刻を照合し、合わなければ終了しません。通常利用のChromeは対象外です。起動用のフラグはChromiumの[ユーザーデータディレクトリの公式資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)に従っています。

Debug版とRelease版は別のbundle IDと保存先を使います。Debug版へ以前のRelease版のデータを自動で取り込みません。通常データを使わない操作確認では、ビルド構成にかかわらず `LEVISTICA_EPHEMERAL=1` を明示します。

## タブと保存の現在の挙動

「ページ」メニューからタブを保持する設定と、選択中のタブの手動休眠を選べます。休眠時は確認を経てページを解放します。再開はURLからの新規読み込みです。ページ内の履歴・入力・スクロール・再生位置は復元しません。保持中、入力を検知したページ、転送・メディア等の保護対象は休眠を拒否します。自動休眠は行いません。保持と休眠の設定は再起動後も残り、選択中でも休眠中のページは自動で読み込みません。固定5文書での予備計測はPLAN.mdに記録しています。実サイトでの削減量は未確認です。

Cmd-Tで追加、Cmd-Wで閉じ、Cmd-Shift-Tで直前に閉じたタブを読み込み直せます。最後のタブを閉じると空タブを残します。ページ内検索はCmd-F、ズームはCmd-+/−/0です。閉じたタブは同じ起動中の直近20件までで、フォーム値やページの内部状態を保存しません。POST後のページは勝手に再送せず、URLの確認を案内します。

Cmd-Dで現在のページをブックマークに追加します。Cmd-Option-Bかアドレス欄左のボタンで一覧を開き、名前・URLの検索、名前変更、新しいタブで開く操作、削除ができます。同じURLを再追加しても編集した名前は保ちます。直前の削除1件は同じ起動中に戻せます。最大1000件で、一覧を初めて使うまで読み込みません。通常起動ではbookmarks.sqlite3へ保存し、隔離起動では終了時に消えます。ローカルPDF、POST結果、識別できる認証パラメータ付きURLは追加できません。

Cmd-Yか時計のボタンで閲覧履歴を開きます。読み込みが完了したGETページを記録し、名前・URLをReturnで検索できます。保存は同じURLの最新訪問だけとし、最大10000件、一覧は200件までです。記録・一覧表示時に90日を超えた履歴を整理します。個別削除と確認つき全削除ができ、開いているタブ、ブックマーク、ログイン情報は残ります。正常終了では待機中の履歴処理を待ちます。隔離起動の履歴は終了時に消えます。同一ページ内だけで切り替わるSPAの移動は今後実装します。

タブID・順序・選択・タイトル・URLを、アプリのsandbox内Application Support/Levistica/session.sqlite3へ保存します。正常終了後は選択したGETページだけを読み込み、異常終了後は一覧だけで起動します。識別できる認証用パラメータ付きURLを除外しますが、任意のURLの秘密情報を完全に判定できるものではありません。DBも個人データとして扱い、Gitや診断ログへ入れません。破損や新しい形式を読めない場合は原本を残し、その起動では書き込みません。正常終了で本体の保存ができた場合は、検証済みの副本を `session.sqlite3.backup` へ1件保存します。更新に失敗しても前の副本を残し、本体が保存済みなら終了できます。副本もタブのURLとタイトルを含む個人データです。起動時に本体を読めず、正常な副本がある場合は、日時・タブ数を確認して一覧を復旧できます。原本は残し、別のDBへ保存します。ページは選択して開くまで読み込みません。復旧後の保存先は、同じフォルダの `current-session.json` で指定します。

Commandクリックは背面の別タブ、Command＋Shiftクリックは選択する別タブに開く操作です。`target=_blank` や利用者操作の `window.open` は、WebKitが渡す設定を使って別タブに開き、要求元originをアプリ側に表示します。子ページから元ページへの結果通知と、その子を閉じる経路も実装済みです。ページが指定したウィンドウ寸法による独立ウィンドウは作りません。自動ポップアップを許可せず、同じページから1秒間に5件を超える追加要求も止めます。これらは実サービス全般の認証対応を保証するものではありません。

## プライバシー設定

Cmd-,で設定を開けます。「履歴」では記録の停止・再開と、1・7・30・90・365日の保存期間を選べます。停止しても期間内の既存履歴は残り、再開しても停止中の訪問は追加しません。期間を短くするときは、古い履歴を削除する確認が必要です。設定は履歴と同じ保存先へ記録し、隔離起動ではその起動だけに適用します。

「サイトデータ」の一覧から、ドメインごと、またはすべてのCookie・キャッシュ・サイト内の保存データを削除できます。ログアウトやサイトでの作業に影響するため、対象を確認してから削除します。削除後に一覧を取り直し、データが残っていれば再試行を案内します。開いているページは再読み込みせず、履歴・ブックマーク・タブ一覧・保存済みダウンロードは残します。ページが保存し直す場合は対象のタブを閉じてから試してください。削除中の終了は取り消して案内します。

一覧にはWebKitが示すドメインと種類だけを表示し、Cookieの値や保存内容は読みません。表示・検索は先頭1000件までで、全削除は表示されていないサイトも対象です。SafariやChromeの保存先は変更しません。

## ダウンロードと添付

ダウンロードでは要求元を確認して保存先を選びます。同名ファイルの置換は標準ダイアログで確認し、転送が完了してから保存先へ反映します。進捗・取消・失敗をアプリ下部に表示し、完了後はFinderで確認できます。ファイルを自動で開くことはありません。

進行中の転送は4件までで、保存先の選択は一度に1件です。転送中の元タブは閉じず、終了時はアプリに戻るか転送を取り消して終了するかを選べます。通信断や取消では部分ファイルを完成品として保存しません。保存先への反映に失敗した場合は一時データを残し、その起動中にFinderで確認できます。再保存、再開、再起動後の転送復旧、残った一時データの回収は今後実装します。

サイトの添付欄から開く標準ダイアログには要求元を表示します。利用者が選んだファイルだけをWebKitへ渡し、フォルダ選択では中のファイルも渡ることを案内します。権限はOpen/Saveダイアログで選んだものへの読み書きに限定し、Downloadsフォルダ全体の権限は追加していません。

## 外部リンクと再表示

他のアプリからHTTP/HTTPSのリンクを受け取り、既存ページを残して新しいタブへ開けます。まとめて渡されたリンクは、最後のタブだけを先に読み込みます。閉じたウィンドウはDockやリンクの受信で再表示します。Macの既定ブラウザは変更しません。

## サイトの確認と入力

サイトのメッセージ・確認・簡単な入力は、要求元を示した標準ダイアログへ表示します。背面タブからは表示せず、同じ文書では5回までに制限します。「このページのダイアログを停止」を選ぶと、その文書の以後の要求を取り消します。再読み込みで再び表示できます。入力中のタブ閉鎖やアプリ終了の確認は、これとは別の実装です。

## PDF資料を開く

Web上のPDFはタブ内で表示します。Cmd-Fで検索、Cmd-+/−/0で拡大・縮小できます。GETで表示したPDFはCmd-Sで保存先を選び、URLから再取得して保存します。送信結果のPDFを勝手に再送しないよう、POST後のPDFではこの保存を無効にしています。入力・注釈を反映した保存には対応しません。

ローカルPDFはCmd-Oから選択します。選んだファイルだけを読み、終了後の自動再読込は行いません。再起動後や閉じたタブを戻したときは、ファイルを選び直してください。ファイル選択を取り消しても、開いているページは残ります。

### 合成動画の比較

既に利用できるffmpegで比較用映像を生成します。ffmpegがない環境では、この手順だけを省略して必要性を相談し、ビルドのために自動導入しないでください。

```bash
mkdir -p .local/artifacts/video
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30:duration=30 -an -c:v libx264 -threads 2 -preset fast -crf 23 -pix_fmt yuv420p -movflags +faststart .local/artifacts/video/synthetic-720p.mp4
python3 script/media-fixture.py --state .local/artifacts/video-comparison/state.json
```

正式入口から隔離起動したReleaseで表示URLを開き、再生ボタンを押します。比較用Chromeも新規専用プロファイルで同じURLを開き、fixtureが記録する表示領域とDPRをそろえます。再生中は `python3 script/measure-memory.py --label fixed-video --loaded-pages 1 --total-tabs 1 --samples 1 --ready-file .local/artifacts/video-comparison/state.json --ready-delay 120` で計測できます。Chromeの計測時は既存のbrowser・chrome-profile指定も加えてください。一度に起動する比較対象は片方だけとし、試行ごとに新しく起動します。計測前後に停止・非表示・再生進行の停止・表示領域の変更を検知した標本は無効です。映像ファイルと結果はGit対象外で、YouTube・音声・DRMの対応をこの比較だけで判断しません。

### 読込済み5タブの比較

`python3 script/document-set-fixture.py --state .local/artifacts/five-documents/state.json` で5文書を配信します。正式入口から隔離起動したLevisticaで、表示されたURLの末尾へ `/1`〜`/5` を加えた文書を、新規タブで順に表示してください。最後は5番を選択し、「5タブ・読み込み済み5」を確認します。

比較用Chromeは既存のstartコマンドに `--tabs 5 --ready-file .local/artifacts/five-documents/state.json` を加えます。専用user-data-dirを指定した起動引数で1件ずつ前面表示し、各タブの報告を待ちます。通常利用のChromeへキー操作を送りません。試行ごとに比較対象だけを終了し、fixtureの同じloopback originへPOST `/reset` を送って報告を初期化します。

計測時は `--loaded-pages 5 --total-tabs 5 --samples 1 --ready-file .local/artifacts/five-documents/state.json --ready-delay 120` を指定します。全タブを一度表示し、各タブの本文・固有instance・報告の新しさを照合できた標本だけが有効です。前面タブからのBroadcastChannelにも各タブが応答するため、純粋な待機状態とは区別します。タブ数だけの比較や、異なるoriginのSNS5件の結果には広げません。

### 手動休眠の前後を測る

5件限定のlifecycleモードは、全件を読み込んだ状態と、1〜4番を休眠して5番を残した状態を比較します。通常の5件・20件比較とは別の文書hash・条件です。通常プロファイルを使わず、隔離Releaseで各URLを順に表示し、799×683・DPR 2と「5タブ・読み込み済み5」を確認します。

```sh
python3 script/cross-site-fixture.py --lifecycle --state .local/sleep/state.json
# state.jsonのurlsを順に開き、5番を選択した状態で別のターミナルから実行
python3 script/sleep-state.py --state .local/sleep/state.json --output .local/sleep/checkpoint.json
python3 script/measure-memory.py --label sleep-before --loaded-pages 5 --total-tabs 5 --samples 1 --ready-delay 120 --ready-file .local/sleep/state.json --sleep-baseline .local/sleep/checkpoint.json
# 1〜4番を確認付きで休眠し、5番へ戻す。接続終了と報告停止を10秒以上確認してから実行
python3 script/measure-memory.py --label sleep-after --loaded-pages 1 --total-tabs 5 --samples 1 --ready-delay 120 --ready-file .local/sleep/state.json --sleep-baseline .local/sleep/checkpoint.json --sleeping-documents 1,2,3,4
```

各状態で120秒待ち、5秒ごとに文書・接続・圧迫条件を確認します。報告停止だけでは休眠と判断せず、UIのタブ数と読み込み済み数も別に記録してください。休眠前だけの標本や不成立の回は前後比較へ加えません。計測後はfixtureをCtrl-Cで終了します。結果と条件の限界はPLAN.mdに記録します。


反復時の保持を調べる場合は、単回比較のcheckpointを流用せず、`--cycle`で全件表示時の履歴を保存します。各回の休眠後は`--sleep-cycle-checkpoint`を渡し、読み込み済み1の同じ状態で測ります。

```sh
python3 script/sleep-state.py --cycle --state .local/sleep/state.json --output .local/sleep/cycle-1.json
# 1〜4番を確認付きで休眠し、5番へ戻してから測定
python3 script/measure-memory.py --label sleep-cycle-1 --loaded-pages 1 --total-tabs 5 --samples 1 --ready-delay 120 --ready-file .local/sleep/state.json --sleep-cycle-checkpoint .local/sleep/cycle-1.json
# 4ページを再開して5番を選択し、次の全件表示時の履歴を追加
python3 script/sleep-state.py --cycle --previous-cycle .local/sleep/cycle-1.json --state .local/sleep/state.json --output .local/sleep/cycle-2.json
```

全件表示時と休眠後のUIの件数も記録し、5件目までを上限にしてください。欠けた再開、余分な接続、5番の再読み込み、履歴の変更を拒否します。前回の単回比較や異なる条件の標本とは混ぜません。反復の5点と未解明の増加はPLAN.mdに記録しています。
