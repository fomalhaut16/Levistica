# Levistica

macOS用のWebブラウザです。現在開発中です。

## 起動

macOS 26以降で動作します。Xcode 26.6以降とPython 3を用意し、リポジトリのディレクトリで実行してください。

```sh
CONFIGURATION=Release ./script/build_and_run.sh
```

次回からは `.local/DerivedData/Build/Products/Release/Levistica.app` をFinderから開けます。

## 操作

アドレス欄へURLや検索語を入力し、Returnを押してください。検索にはDuckDuckGoを使います。

| 操作 | ショートカット |
|---|---|
| アドレス欄へ移動 | Cmd-L |
| 新しいタブ／閉じる | Cmd-T／Cmd-W |
| 閉じたタブを開き直す | Cmd-Shift-T |
| 戻る／進む | Cmd-[／Cmd-] |
| ページ内検索 | Cmd-F |
| ブックマークへ追加 | Cmd-D |
| 履歴 | Cmd-Y |
| PDFを開く | Cmd-O |
| 設定 | Cmd-, |
| 終了 | Cmd-Q |

左の一覧でタブを検索・並べ替えできます。「ページ」メニューではタブの保持と手動休眠を選べます。休眠したページは読み込み直すため、入力内容や再生位置は戻りません。

終了後もタブ一覧は保存されます。フォームへの入力内容は復元しません。履歴やCookieなどの削除は設定から行えます。
