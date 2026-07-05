# App Store メタデータの更新手順（CreditMemo）

説明文（description）とプロモーションテキスト（promotional_text）を
**5言語**まとめて App Store Connect に反映するための fastlane 設定です。

- 対象アプリ: `com.azukid.AzCreditS1`（App ID は未設定。bundle ID だけで動く）
- 更新される項目: `description` と `promotional_text` のみ
  （キーワード・スクショ・価格・バイナリは触りません）

対応ロケール（App Store Connect のコード）:
`ja` / `en-US` / `de-DE` / `ko` / `zh-Hant`

各テキストは `fastlane/metadata/<locale>/description.txt` と
`fastlane/metadata/<locale>/promotional_text.txt` にあります。
**現状は空ファイル**です。中身を書けばその項目だけが反映対象になります
（空のままの項目は既存を上書きしません）。

---

## 1. 準備（初回のみ）

### 1-1. fastlane
この Mac では **Homebrew 版 fastlane**（`/opt/homebrew/bin/fastlane`）を使います。
システム Ruby 2.6 は古いので `bundle exec` ではなく `fastlane <lane>` を直接呼びます。

### 1-2. App Store Connect API キー（.p8）を発行
App Store Connect → **ユーザーとアクセス** → **統合（Integrations）**
→ **App Store Connect API** → **キーを生成**（ロールは `App Manager` 以上）

> ⚠️ ロールが `Developer` だと 403（The API key in use does not allow this request）。
> 既存キーのロールは変更不可なので、その場合は新しいキーを発行してください。

発行時に控える／保存する:
- **Key ID**（例: `ABC123DEFG`）
- **Issuer ID**（UUID）
- **AuthKey_XXXX.p8**（ダウンロードは1回だけ・再取得不可）

`.p8` は `fastlane/` 直下に置くと `.gitignore` 済みで安全です:
```bash
mv ~/Downloads/AuthKey_ABC123DEFG.p8 fastlane/
```

### 1-3. .env を作成
```bash
cd /Users/sumpositive/GitLocal/CreditMemo
cp fastlane/.env.example fastlane/.env
# fastlane/.env を編集して ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH を実値に
```
`.env` は `.gitignore` 済み。CreditMemo ディレクトリ内で fastlane を実行すると自動読込されます（export 不要）。

---

## 2. 実行

### 2-1. まず内容確認（送信前に確認プロンプトで停止）
```bash
cd /Users/sumpositive/GitLocal/CreditMemo
fastlane preview_metadata
```
`force: false` なので Preview.html を生成して y/n を尋ねます。
（非対話環境＝Claude のサンドボックスでは応答できないため停止します。ユーザーの手元で実行してください）

### 2-2. 反映（審査提出はしない）
```bash
fastlane upload_metadata
```
`submit_for_review: false` なので、メタデータが保存されるだけで**審査には出ません**。

---

## 3. テキストを直したいとき

該当ファイルを編集して、再度 `upload_metadata` を実行するだけです:
```
fastlane/metadata/<locale>/description.txt
fastlane/metadata/<locale>/promotional_text.txt
```

文字数の目安（App Store の上限）:
- description: 4000 文字
- promotional_text: **170 文字**（実カウントで検証すること。ドイツ語は溢れやすい）

---

## 4. 補足

- `deliver` は「置いてあるファイルの項目だけ」を更新します。keywords.txt などを
  置いていないので、既存のキーワード等は上書きされません。
- **release_notes（What's New）は配信済み(Ready for Sale)バージョンだと編集ロック**され
  更新できません。その場合は次バージョンを App Store Connect 側で用意してから反映します
  （このプロジェクトでは release_notes.txt は未配置＝触りません）。
- App Store への送信を伴う対話実行（Preview.html の y/n）は Claude のサンドボックスでは
  できないので、ユーザーの手元（Mac）で実行する前提です。
