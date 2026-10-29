# Levistica

macOS用のWebブラウザです。現在開発中です。

## 起動

macOS 26以降で動作します。Xcode 26.6以降とPython 3を用意し、リポジトリのディレクトリで実行してください。

```sh
CONFIGURATION=Release ./script/build_and_run.sh
```

次回からは `.local/DerivedData/Build/Products/Release/Levistica.app` をFinderから開けます。

ZIPにまとめる場合は、次を実行してください。

```sh
CONFIGURATION=Release ./script/build_and_run.sh --package-local
```

表示されたZIPを展開すると、`Levistica.app` をFinderから開けます。このZIPは手元のMacでの利用向けです。配布用の署名・公証は行いません。

初めてApplicationsフォルダーへ設置する場合は、表示されたパッケージディレクトリを指定します。

```sh
CONFIGURATION=Release ./script/build_and_run.sh --install-package-local PACKAGE_DIRECTORY
```

設置後は、ユーザーのApplicationsフォルダーにある `Levistica.app` を開いてください。同名のアプリが既にある場合は、上書きせず停止します。

## 操作

アドレス欄へURLや検索語を入力し、Returnを押してください。検索先は設定の「一般」でDuckDuckGo／Googleから選べます。 URL欄の左にある接続情報から、表示中のページの接続先と暗号化の状態を確認できます。

| 操作 | ショートカット |
|---|---|
| アドレス欄へ移動 | Cmd-L |
| 新しいタブ／閉じる | Cmd-T／Cmd-W |
| 閉じたタブを開き直す | Cmd-Shift-T |
| 戻る／進む | Cmd-[／Cmd-] |
| ページ内検索 | Cmd-F |
| タブを検索 | Cmd-Shift-A |
| ブックマークへ追加 | Cmd-D |
| 履歴 | Cmd-Y |
| PDFを開く | Cmd-O |
| 設定 | Cmd-, |
| 終了 | Cmd-Q |

タブの縦・横配置は、URL欄横の切り替えボタンか設定の「一般」で選べます。タブ一覧で検索・並べ替えできます。タブの検索欄でReturnを押すと、最初の検索結果へ移ります。新しいタブで開くページは、設定の「一般」で指定してください。「ページ」メニューではタブの保持と手動休眠を選べます。休眠したページは読み込み直すため、入力内容や再生位置は戻りません。

終了後もタブ一覧は保存されます。フォームへの入力内容は復元しません。履歴やCookieなどの削除は設定から行えます。

ブックマーク一覧の「HTMLから取り込む…」で、Chromeなどから書き出したブックマークHTMLを取り込めます。プレビューを確認してから追加し、既存項目は変更しません。フォルダーの絞り込みも使えます。上限は合計1000件・ファイル8MiBで、空のフォルダーやHTTP/HTTPS以外のリンクは対象外です。
