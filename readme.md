# CreditMemo / クレメモ 開発メモ

この `readme.md` は、開発者向けの設計メモです

## Xcodeプロジェクト管理方針

- 本プロジェクトはXcode管理で運用する
- `CreditMemo.xcodeproj`をプロジェクト設定の正本とする
- ターゲット、Build Settings、Build Phases、Asset Catalogなどの設定変更はXcodeから行う
- `project.pbxproj`はXcodeが更新した内容をそのままGit管理する
- XcodeGenは使用しない
- `project.yml`からXcodeプロジェクトを再生成しない
- ファイル追加時はXcode上のTarget Membershipも確認する

## プロジェクト名とアプリ名の使い分け

本プロジェクトでは、プロジェクト識別子と公開アプリ名を **意図的に揃えず別物として運用** します。

- **`CreditMemo`** — プロジェクト名・フォルダ名・Xcode target・Swift コード上の識別子・SwiftData ストア名 (`Application Support/CreditMemo.store`)・GitHub リポジトリ名
- **`CrediMemo` / `クレメモ`** — App Store 上の公開アプリ名・取扱説明のユーザー向け本文・UI 文言・アイコン alt などユーザーが目にする表記

理由は、`CreditMemo.store` を改名すると既存ユーザーの SwiftData ストアとの互換性が失われるためです。内部識別子（フォルダ・コード・ストア名）は据え置き、ユーザー向け表記だけ `CrediMemo` / `クレメモ` に揃えます。混在は仕様であり、リファクタリングで自動的に統一しないでください。

**User Guide**  
[English](https://azukid.com/en/sumpo/CreditMemo/creditmemo.html) / [日本語](https://azukid.com/jp/sumpo/CreditMemo/creditmemo.html)

![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Version](https://img.shields.io/badge/version-2.4.0-brightgreen)
[![App Store](https://img.shields.io/badge/App%20Store-Download-blue)](https://apps.apple.com/us/app/id432458298)

## バージョン 2.4.0 の主な変更

- **音声で新しい決済**
  - メインメニュー先頭に「音声で新しい決済」を追加し、発話だけで明細を保存できる
  - 第1フェーズ: 金額とラベルを聞き取る。数値が金額、それ以外がラベルになる
  - 第2フェーズ: 「決済手段を音声入力する」ボタンで手段専用フェーズへ切替。検出した手段はタップで一覧から選び直せる
  - 選び直した結果は `VoiceAliasStore`（UserDefaults）に学習され、次回以降の音声判定に反映される
  - 設定 > 決済・支払の先頭に「音声入力を使う」スイッチを追加（既定 ON）
  - ロケール対応: `SFSpeechRecognizer` が対応する全ロケールで自動有効化（ja-JP / en-US 等）
  - 数値解析は ja-JP のみ漢数字・万・千・円を解釈、他ロケールは半角数字のみ
- **Siri / App Intents 連携**
  - 「Hey Siri クレメモで音声入力」で音声入力フェーズを直接起動できる
  - `AppIntent` を経由してアプリを開き、メインメニューから「音声で新しい決済」へ自動遷移する
  - ショートカット App からも同じインテントを呼び出せる
- **配色プリセット 12 種**
  - 設定 > 表示 から、引き落とし状況とメニューアイコンの配色を 12 種類のプリセットから選択できる
  - 選択したプリセットはアプリアイコンにも反映され、ホーム画面の見た目を切り替えられる
  - 既定プリセットは「ブルー / グレー」で、未払 / 済み / 確認待ちの 3 状態が判別しやすい配色
- **アプリアイコン刷新**
  - 中央バンドを 青 / グレーに更新（旧 オレンジ / グリーン）
  - 境界の白い発光ラインを倍幅化し、左右が暗く中央が明るく盛り上がるリッジ風に変更
  - 小豆色の背景グラデーションを一段深くし、新しい中央デザインが映えるよう調整
- **JSON インポート改善**
  - 部分 JSON の受け入れ判定をより寛容にし、欠損キーがあってもマスタ／履歴の取り込みを継続する
  - `E1card` の請求方式を現行正規形（`nClosingDay / nPayMonth / nPayDay`）へ自動整形し、旧形式の JSON も矛盾なく取り込む
  - `E2invoice / E7payment` の重複キーを取り込み中に正規化し、二重表示を防ぐ

## バージョン 2.2.0 の主な変更

- **金額未定時のテンキー自動表示を ON/OFF**
  - 設定の `新しい決済で自動的にテンキーを開く` で切り替えできます（デフォルト ON）
  - OFF の場合、テンキーを閉じても新しい決済画面は閉じません
- **新しい決済をコピーして作る経路を拡充**（旧アプリ相当の導線を復活）
  - 決済一覧の **金額が一致** する明細をコピー
  - 決済一覧の **最近編集した** 明細をコピー
  - 決済手段一覧にある明細をコピー
  - 引き落とし明細の **引き落とし日 + 決済手段** をコピー
- その他、改善・不具合修正
  - メインメニュー直下の各画面タイトルにアイコンを表示
  - アイコンサイズを文字サイズに連動（上限は「大」）
  - 引き落とし状況のグループ軸切替時の表示不具合を修正
  - 締日/支払日型カードからの新規決済で利用日が当日に揃うよう修正

## バージョン 2.1.0 の主な変更

旧アプリで好評だった機能を復活・再構成しました。

- **明細ごとの引き落とし日変更**
  - `E6part` 単位で、引き落とし日（所属 `E2invoice` の日付）を後から変更できる
  - 変更すると `E7payment` の所属も付け替わり、`引き落とし状況` 画面で正しい位置へ移動する
- **引き落とし状況 (`PaymentListView`) の集計/絞り込み刷新**
  - 集計軸を `日付 / 手段 / 口座` から切り替えられる
  - 絞り込みは `すべて / 手段 / 口座` を選択でき、手段・口座を選ぶと集計軸を日付へ戻す
  - 絞り込み後は、行数が多い場合は未払/済み境界、行数が少ない場合は先頭へスクロールして見失いを防ぐ
- **明細のロック機能**（旧 `確認チェック` 機能の再現）
  - `E6part.isChecked` を解錠 / 施錠アイコンとして UI に露出
  - 施錠中の明細は引き落とし日の変更を禁止する（誤操作防止）
  - `sumNoCheck` の集計はカード・請求書・支払の各層へ波及する
- **履歴 (`RecordListView`) のソート/フィルター刷新**
  - 対象期間に `3ヶ月 / 1年 / 3年 / 全` を用意（デフォルトは1年）
  - フィルターは `すべて / 未入力あり / 手段 / 口座 / タグ(複数選択)` を選べる
  - `未入力あり` は決済手段未設定・決済ラベル未入力だけを対象とし、タグ未選択は含めない
  - 並び順は `日付 / 金額` を選び、それぞれ昇順/降順を切り替えられる
- **決済手段マスタの導線整理**
  - 決済手段一覧の行タップは、状況表示ではなく編集画面を開く
  - 状況確認は `引き落とし状況` の集計/絞り込みへ集約する
- **日付表示の共通化**
  - `Components/StackedDateView.swift` を導入し、履歴・引き落とし状況・引き落とし明細の3段日付表示を共通化
  - 年・曜日は `.caption2 / .caption` で Dynamic Type に追従する

## アプリ前提

- 対象は、**後日口座から引き落とされる決済**です
- 即時に残高や現金が動く決済は対象外です

## データ構造の考え方

### 基本方針

- 旧アプリのデータ構造を継承しています
- 変更点は、`E7payment` を **口座別に扱えるようにしたこと** だけです
- `E4shop` は現行 SwiftData スキーマから撤去しています
- 旧 `shop` データは、旧データ読込時だけ `E5tag` へ寄せて扱います
- 画面仕様の都合でデータ構造に影響しそうになった場合も、まずはサービス層や表示側で吸収し、データ構造の変更は慎重に行うこと

### 正本

- `E3record`
  - ユーザーが入力する決済明細の正本です
  - 利用日、金額、決済手段、決済ラベル、タグなどを持ちます

### 派生

- `E6part`
  - `E3record` から派生する支払パーツです
  - 旧データ互換のためモデルは残しています
- `E2invoice`
  - カード単位の請求です
  - 実質的には `日付 + カード + 状態` 単位です
- `E7payment`
  - 口座引き落とし単位の集計です
  - 実質的には `日付 + 口座 + 状態` 単位です

### 状態表現

- `paid / unpaid` は保存 `Bool` ではなく、**所属リレーション**で表します
- `E2invoice`
  - `e1paid != nil` なら済み
  - `e1unpaid != nil` なら未払
- `E7payment`
  - `e8paid != nil` なら済み
  - `e8unpaid != nil` なら未払
- `isPaid` は UI や集計用の **計算プロパティ** として扱います

### 親モデル

- `E1card`
  - `e2paids / e2unpaids` を持ちます
- `E8bank`
  - `e7paids / e7unpaids` を持ちます

### 決済手段の正規形

- `E1card` は、現行では **`nClosingDay / nPayMonth / nPayDay` の 3 項目だけ**で請求方式を表します
- 判定は次の通りです
  - `nClosingDay == 0`
    - `N日後型`
    - `nPayDay == N`
    - `nPayMonth == 0`
  - `nClosingDay != 0`
    - `締日 / 支払日型`
    - `nClosingDay == 締日`
    - `nPayMonth == 支払月`
    - `nPayDay == 支払日`
- `nBillingType` や `nOffsetDays` のような補助表現は使いません
- 新規保存、プリセット、JSON 入出力はすべてこの正規形に揃えます

## この構造の狙い

- 旧アプリの `paid / unpaid` 付け替え方式を維持する
- 未払一覧 / 済み一覧を高速に引けるようにする
- `引き落とし状況` 画面で必要な単位である `日付 + 口座` に `E7payment` を合わせる
- 画面側の仮想グルーピングや補正を減らす

## 留意点

- `E3record` を編集して `E1card.e8bank` が変わると、既存の `E2invoice / E7payment` の再配置が必要です
- `E7payment` は日付だけで一意ではありません。必ず **口座** と **状態** を含めて扱う必要があります
- `E2invoice` も `日付 + カード + 状態` を前提に扱います
- `sumAmount` や `sumNoCheck` は派生集計値です。正本ではありません
- 画面表示の都合で永続モデルを増やさず、まず永続モデルの責務を明確に保ちます

## トランザクション方針

SwiftData には DB トリガやストアドプロシージャーはないため、永続化と派生データの整合は **Service 層に集約** します。View / ViewModel から `ModelContext` の更新系 API を直接呼ばないのが基本ルールです。

### 基本原則（最重要）

- **永続化を伴う操作は必ず Service 経由**で行う
  - View / ViewModel / その他レイヤーから `context.insert(_:)` / `context.delete(_:)` / `context.save()` を直接呼ばない
  - 例外（後述）に該当しない場合、これは設計違反として扱う
- 1 回のユーザー操作 = 1 回のサービス呼び出し = 1 回の `context.save()`
- 派生データ（`E2invoice` / `E7payment` / `E6part`）の再構築や所属移動は、サービス内で完結させる
- サービスの途中で `context.save()` を挟まず、終端で 1 回だけ行う
- バッチ処理（履歴大量再構築など）でバッチごとに保存する場合は、各バッチを「小さな 1 操作」とみなし、失敗時は `context.rollback()` で巻き戻す

### Service 一覧と責務範囲

| Service | 対象 | 主な API |
|---|---|---|
| `RecordService` | `E3record` / `E6part` / `E2invoice` / `E7payment` / 集計値 | `save` / `delete` / `setInvoicesPaid` / `setPartPaid` / `setPartDueDate` / `cleanupOrphanBilling` / `checkBillingIntegrity` / `rebuildBilling` |
| `CardService` | `E1card` の CRUD（派生影響を含む） | `create` / `applyEdits`（口座/締日/支払日変更時の再構築まで） / `delete` |
| `BankService` | `E8bank` の CRUD（派生影響を含む） | `create` / `delete`（配下カード参照解除 + payment 整理まで） |
| `JSONImport` / `JSONExport` | 全モデル一括の入出力 | `importData(from:context:)` / `exportData(context:style:)` |

### 主な処理単位

- `RecordService.save(record)`
  - `E3record` の保存、`E6part` の再構築、`E2invoice / E7payment` の再配置、集計値更新、最後に `context.save()`
- `RecordService.delete(record)`
  - `E3record` の削除、関連 `E6part` の削除、空になった `E2invoice / E7payment` の掃除、集計値更新、最後に `context.save()`
- `RecordService.setInvoicesPaid` / `setInvoicePaid` / `setPartPaid`
  - `paid / unpaid` 所属の付け替え、必要に応じた繰り返し明細の生成、集計値更新、最後に `context.save()`
- `CardService.applyEdits`
  - カードのフィールド更新、口座/締日/支払日変更時は配下 `E3record` のバッチ再構築 + `cleanupOrphanBilling`、最後に `context.save()`
- `CardService.delete` / `BankService.delete`
  - 派生 invoice / payment の組み直し、孤児掃除、本体削除、最後に `context.save()`

### View 側の許容パターン

以下だけ、View から `context` の更新系 API を呼んでよい（実装現状とも一致）:

1. **マスタの軽量編集（rename / メモ更新）** — `E5tag` / `E8bank` / `E1card` の `zName` / `zNote` 等、派生影響のないプロパティ変更は、View で代入してから SwiftData の autosave に任せる
2. **`E5tag` の作成・削除** — タグは `E3record.e5tags` への影響が `@Relationship(deleteRule: .nullify)` で吸収されるため、`TagEditView` で `context.insert` / `context.delete` を呼ぶ運用を許容する
3. **`context.insert` 直後の Service 呼び出し** — `RecordService.save(record)` に渡すために、その直前に `context.insert(record)` を呼ぶのは許容する。永続化責務は Service が持つ

これら以外の `context.insert` / `context.delete` / `context.save` を View に書きたくなったら、まず該当 Service の API を探し、無ければ Service に新設する。

### 実装上の注意

- `willSave` / `didSave` に業務ロジックを分散させない
- 派生値はサービス層で明示的に再計算する
- 進捗 UI が必要なバッチ処理は、Service が `(completed, total)` を返すコールバックを受け取り、View は表示のみを担う（例: `CardService.applyEdits(... onBillingProgress:)`）
- 規律確認は `grep -rn "context\.insert\|context\.delete\|context\.save" Features` で目視する。新規追加箇所は Service へ寄せる
- 旧データ互換のためモデルに残っている要素と、新規運用で使う要素を混同しない

## migration 方針

- 対応対象は **旧アプリ Core Data**（`AzCredit.sqlite`）のみです
- 旧 `payment` はそのまま移さず、**旧 invoice から `日付 + 口座 + 状態` の `E7payment` を再構成**します

### 失敗時の再試行

- 移行成功時のみ旧ファイルを `AzCredit.sqlite.done` にリネームし、移行済みフラグを立てます
- 移行失敗時はファイルをそのまま残し、フラグも立てません → **次回起動で自動再試行**します
- 失敗ダイアログでは「スキップ（次回再試行）」か「旧データを破棄して新規開始」の2択です
- iCloud バックアップ復元後に `-wal`/`-shm` が欠けている場合は、空ファイルを作成してから CoreData を開きます（WAL 補修）

### SwiftData ストアファイル

- ストア名は **`CreditMemo`**（`Application Support/CreditMemo.store`）
- `default.store`（名前未指定時のデフォルト）が残っている場合は、起動時に `CreditMemo.store` へ自動リネームします

## JSON 入出力方針

- 設定画面から、全データ JSON のエクスポート/インポートを行います
- インポートは **置換ではなく merge(upsert)** を基本とします
- エキスポート形式は 2 種類あります
  - `コンパクト`
    - 空白や改行を抑えた保存向け JSON
  - `プリティ`
    - 人が見やすい整形表示向け JSON
- JSON は全件前提に限定せず、以下のような **部分データ** も受け入れます
  - 口座・決済手段・タグなどのマスタのみ
  - 一部の決済履歴のみ
  - 状態情報だけを含む JSON
- 配列キーが欠けている場合は、その配列を **未指定として無視** します
- `E2invoice / E7payment` もエクスポートします
- インポート時はまず `E3record` から請求を再構築し、その後に JSON 側の `invoice / payment` の未払/済み状態を反映します
- このため、JSON インポートの主眼は
  - 正本である `E3record` と各マスタの取り込み
  - `invoice / payment` の状態復元
  にあります。
- JSON インポート時は、決済手段設定も現行正規形へ寄せて取り込みます
  - `closingDay == 0` の時は `payMonth = 0` を強制します
  - これにより、`N日後型` に矛盾した JSON が入っても現行仕様へ正規化されます

## 最近の改善点

### `E7payment` の単位見直し

- 旧アプリ構造の中で、実運用に合わせて改善した主な点はここです
- `E7payment` は `日付` 単位ではなく、**`日付 + 口座 + 状態` 単位**で扱います
- これにより、同じ引き落とし日でも口座が違う請求を自然に分けて扱えます
- `引き落とし状況` と `引き落とし明細` は、この単位をそのまま表示する前提です

### 引き落とし状況の表示軸

- `引き落とし状況` は、保存モデルを増やさずに表示用モデル `PaymentDisplayItem` へ変換して見せます
- 集計軸は `日付 / 手段 / 口座` を切り替えられます
- 絞り込みは `すべて / 手段 / 口座` です
- 手段や口座を指定した場合は、対象の時系列が見やすいよう集計軸を `日付` へ戻します
- 行数が多い場合は未払/済み境界へ、行数が少ない場合は先頭へ自動スクロールします

### 口座変更後の再配置修復

- 決済手段の引き落とし口座を変更した場合、その決済手段に属する過去の請求も現在の口座へ再配置します
- `cleanupOrphanBilling` では、既存 `E2invoice` が古い `E7payment` に残っていないか確認し、必要に応じて正しい `日付 + 口座 + 状態` の `E7payment` へ張り替えます
- 修復処理は `E7payment` を先に辞書化してから `E2invoice` を走査し、請求ごとの SwiftData fetch を避けます
- これにより、決済手段編集や JSON インポート後の整合性回復で、古い口座の明細が残る問題を抑えます

### サービス層へ更新責務を集約

- 保存、削除、未払/済み切替は `RecordService` に集約しています
- カード・口座の CRUD（派生影響含む）は `CardService` / `BankService` に集約しています
- View から `invoice / payment` を直接更新しない前提です（許容パターンは「トランザクション方針」参照）
- `context.save()` はサービス終端で 1 回だけ行う方針です

### 重複 `invoice / payment` の正規化

- 同じキーを持つ `invoice / payment` が残ると、一覧や明細で二重表示が起こります
- そのため、保存や再計算時に以下を統合する処理を入れています
  - 同じ `日付 + カード + 状態` の `E2invoice`
  - 同じ `日付 + 口座 + 状態` の `E7payment`

### 一覧の読み込み方針

- 決済履歴は対象期間・フィルター・並び順を適用した上でページ単位で読み込み、初期表示の負荷を抑えます
- 決済履歴の対象期間は `3ヶ月 / 1年 / 3年 / 全` で、デフォルトは1年です
- 決済履歴の `未入力あり` は、決済手段未設定・決済ラベル未入力だけを対象にします
- 引き落とし状況は、未払を全件表示対象とし、済みだけページ単位で読み込みます
- 引き落とし状況の対象範囲は直近1年を基本とし、古すぎる済みデータで画面が重くならないようにします

### shop の扱い

- `shop` 機能は現行アプリでは使いません
- そのため `E4shop` は現行スキーマから削除しています
- ただし、旧 Core Data と旧 JSON 互換のために、旧 `shop` 読込コードは残しています
- 旧 `shop` 由来の情報は、必要に応じて `E5tag` へ寄せて扱います

### 2回払い（分割払い）機能の休止

- 2回払い（`PayType.twoPayments`）機能は現行アプリでは **UI を非表示**にして休止しています
- データ構造・サービス層・`BillingService` の計算ロジックはそのまま温存しています
- 再開する場合は、UI の表示制御（`PayType` 選択肢の復活）と `SplitPayListView` の導線を戻すだけで機能します

### ロック機能（旧 `確認チェック` 機能の復活）

- 2.1.0 で `E6part` 単位の **解錠 → 施錠** トグルとして UI に復活させました（`InvoiceListView` の `PartRow`）
- 内部表現は旧来の `E6part.nNoCheck`（`0=確認済(施錠), 1=未確認(解錠)`）をそのまま使い、`E6part.isChecked` ラッパーで吸収します
- 各モデルの `sumNoCheck` 集計はカード・請求書・支払の各層へ波及します
- 施錠中の明細は、引き落とし日の変更を禁止します（`RecordEditView.canEditPartDueDate` が `!part.isChecked` を確認）
- 旧アプリと同様、**処理ロジックには影響しません**。ユーザーが「通帳・明細書と照合済み」というサインを残すための機能です

## 注意点

### 旧アプリ構造を基準にする

- 正式な基準は **旧アプリ Core Data の構造** です
- 今回の設計見直しでは、旧構造の方が要件に合うと判断しています
- 今後の migration や整合確認も、この構造を基準に行います

### 口座変更は過去請求の再配置を伴う

- `E3record` 自体ではなく、`E1card.e8bank` を変えるため、過去請求の見え方も変わります
- 決済編集で口座を変更した場合は、`E2invoice / E7payment` の再配置が必要です

### 二重表示が出たときの確認観点

- 同じ `日付 + カード + 状態` の `E2invoice` が重複していないか
- 同じ `日付 + 口座 + 状態` の `E7payment` が重複していないか
- 旧 SwiftData ストアの残骸が残っていないか

### 今後の変更方針

- 変更が必要な場合は、以下を満たすときだけ検討します。
  - 旧構造では要件を満たせない
  - migration 方針が明確
  - 表示やサービス層で吸収できない
- まず疑う順序は次の通りです
  1. サービス層の更新責務
  2. 表示ロジック
  3. migration
  4. それでも無理な場合のみ永続モデル

## 開発環境

- Swift 6
- SwiftUI
- SwiftData
- iOS 18 以降

## ライセンス

本リポジトリのソースコードは参照目的で公開しています。  
著作権は SumPositive に帰属します。  
無断での複製、改変、再配布、商用利用を禁止します。

## ローカライズ運用ルール

- ローカライズは **`CreditMemo/Resources/Localizable.xcstrings` に統一**します
- 新しい文言はコードへ直接埋め込まず、必ずキー参照で追加します
- `Localizable.strings` の新規追加は行わず、既存運用の `xcstrings` を使います
