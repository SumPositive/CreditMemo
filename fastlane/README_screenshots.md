# App Store スクリーンショットの自動撮影・アップロード（CreditMemo）

`fastlane snapshot` でシミュレータからスクショを自動撮影し、`deliver` でアップロードします。
**まずは「メイン画面 1 カット × ja/en-US × iPhone 17 Pro Max」で仕組みを検証**し、
動いたら言語・デバイス・カットを増やす方針です。

---

## ステップ 0: 用意済みファイル

Claude が以下を用意済みです:

- `fastlane/uitest/SnapshotHelper.swift` … fastlane 公式ヘルパー（Xcode 26 対応済みの版）
- `fastlane/uitest/CreditMemoUITests.swift` … 撮影用 UI テスト（今はメイン画面 1 カットの骨組み）
- `fastlane/Snapfile` … 撮影対象の言語・デバイス設定
- `fastlane/Fastfile` … レーン `screenshots` / `upload_screenshots` / `screenshots_and_upload`

`fastlane/uitest/` の 2 つの .swift は「置き場所」です。次のステップで Xcode の
UITest ターゲット `CreditMemoUITests` に取り込みます。

> CreditMemo にはすでに `CreditMemoUITests` ターゲット（雛形の testPlaceholder のみ）が
> あります。DialSplit のように新規ターゲットを作る必要はありません。

---

## ステップ 1: Xcode で UITest ターゲットにファイルを紐付け（← 手動 GUI 操作）

1. `CreditMemo.xcodeproj` を Xcode で開く
2. 既存の `CreditMemoUITests/CreditMemoUITests.swift`（testPlaceholder の雛形）の中身を、
   `fastlane/uitest/CreditMemoUITests.swift` の内容で置き換える
   （実体を差し替える運用なら `cp fastlane/uitest/CreditMemoUITests.swift CreditMemoUITests/`）
3. `fastlane/uitest/SnapshotHelper.swift` を Xcode にドラッグして
   **CreditMemoUITests ターゲットにのみ**追加する（Target Membership を UITest だけにチェック）

> SnapshotHelper.swift はアプリ本体ターゲットには入れないこと（UITest 専用）。
> `fastlane/uitest/` を編集したら Xcode 側の実体にも反映すること（両方同期）。

---

## ステップ 2: スキーム設定（テストを共有可能に）

1. Xcode の **Product > Scheme > Manage Schemes…**
2. `CreditMemo` スキームの **Shared** にチェックが入っていることを確認
3. **Edit Scheme… > Test** タブで、`CreditMemoUITests` がテスト対象に含まれていることを確認

（別スキームを作る場合は、`fastlane/Snapfile` の `scheme("CreditMemo")` をその名前に変更）

---

## ステップ 3: 撮影して確認（アップロードしない）

```bash
cd /Users/sumpositive/GitLocal/CreditMemo
fastlane screenshots
```

- 初回はシミュレータのビルド＆起動で数分かかる
- 成功すると `fastlane/screenshots/` に言語別フォルダ＋PNG が出力され、一覧 HTML が開く
- `01MainScreen` が撮れていれば検証成功 🎉

うまくいかない場合の主な原因:
- シミュレータ名が違う → `Snapfile` の `devices([...])` を
  `xcrun simctl list devices` に出る名前に合わせる
- UITest が走らず 0 枚 → `Snapfile` の `only_testing` / `scheme` を確認
- クローン起動が拒否される → 実行前に
  `xcrun simctl shutdown all` +
  `sudo killall -9 com.apple.CoreSimulator.CoreSimulatorService` でクリーンに

---

## ステップ 4: カット・言語・デバイスを増やす（検証OK後）

- **カット追加**: `CreditMemoUITests.swift` の `testTakeScreenshots` 内に、
  画面遷移の操作 + `snapshot("02Settings")` のように追記。
  要素特定はローカライズ文言に依存しない `accessibilityIdentifier` を UI に付けると安定
  （CreditMemo にはまだ識別子が無いので、撮りたい画面のボタンに付与するのが次の作業）。
- **言語**: `Snapfile` の `languages([...])` を 5 言語に（ja/en-US/de-DE/ko/zh-Hant）。
- **デバイス**: iPhone が埋まったら `iPad Pro 13-inch (M5)` を追加（13" は審査必須枠）。

---

## ステップ 5: アップロード（審査提出はしない）

```bash
cd /Users/sumpositive/GitLocal/CreditMemo
fastlane upload_screenshots      # 撮影済みを反映
# または
fastlane screenshots_and_upload  # 撮影 → アップロードを一気に
```

- API キー認証（`.env` の ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH）はメタデータ更新と共通
- `skip_metadata: true` なので説明文等には触らない／スクショだけ差し替え
- `submit_for_review: false` なので審査には出ない

---

## 注意

- **必須サイズは iPhone 6.9"（iPhone 17 Pro Max）** と **iPad 13"（iPad Pro 13-inch (M5)）**。
- `fastlane/screenshots/` は `.gitignore` で除外（再生成可能な成果物）。
  手動撮影した差し替え不可のカット（Stage Manager 等）があれば別途保管する運用に。
- 通貨や地域を画面に出す必要が出たら、DialSplit のように UITest で
  `-SNAPSHOT_CURRENCY_LOCALE` を渡す仕組みをアプリ側（DEBUG 限定フック）に足す。
  CreditMemo で必要になったら相談。
