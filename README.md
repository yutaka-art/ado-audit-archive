# Azure DevOps 変更管理証跡 長期保管基盤

Azure DevOpsの監査ログ対象外である **Pull Request承認・Pipeline実行・ステージ承認の記録** を
REST API経由で抽出し、Log Analyticsへ3年間保管するための実装一式です。

| 項目 | 内容 |
|---|---|
| 版数 | v1.0 |
| 対象Organization | `contoso`（例。実環境の値に置き換えてください） |
| 対象Workspace | `law-contoso-dev`（例） |
| 保持期間 | 1,095日（対話型730日＋長期保持365日） |

---

## ⚠️ 最初にお読みください

| 項目 | 内容 |
|---|---|
| 前提 | CustomLog（HTTP Data Collector API）は **2026年9月14日にサポート終了** |
| 本実装の方式 | **Logs Ingestion API**（Data Collection Rule方式）＋ Entra ID OAuth認証 |

詳細は `docs/01_設計概要.md` 3.1節を参照してください。

---

## 読む順番

| # | ファイル | 対象読者 | 内容 |
|---|---|---|---|
| 1 | `docs/01_設計概要.md` | 全員 | 背景・方式決定・アーキテクチャ・ITGC統制対応 |
| 2 | `docs/02_導入手順書.md` | 構築担当 | STEP 1〜9の構築手順とチェックリスト |
| 3 | `docs/03_検証手順書.md` | 統制責任者・構築担当 | 受入テスト12ケースと結果記録表 |
| 4 | `docs/04_運用手順書.md` | 運用担当・統制責任者 | 月次運用・監査対応・障害対応 |

---

## ディレクトリ構成

```
ado-audit-archive/
├── README.md                              本ファイル
├── docs/
│   ├── 01_設計概要.md
│   ├── 02_導入手順書.md
│   ├── 03_検証手順書.md
│   └── 04_運用手順書.md
├── infra/
│   ├── deploy-ado-audit-archive.json      ARMテンプレート（テーブル4種＋DCR）
│   └── Deploy-AuditArchive.ps1            デプロイスクリプト（冪等）
├── pipelines/
│   └── azure-pipelines-ado-audit-export.yml
├── scripts/
│   ├── AdoAuditExport.psm1                抽出・取込モジュール
│   ├── Export-AdoAuditRecords.ps1         エクスポート本体
│   ├── Test-AdoAuditIngestion.ps1         取込検証スクリプト
│   └── Invoke-OfflineSmokeTest.ps1        オフライン自己テスト（36ケース）
└── kql/
    └── itgc-evidence-queries.kql          監査証跡クエリ集（Q01〜Q11）
```

---

## 何が保管されるか

| テーブル | 内容 |
|---|---|
| `ADO_PullRequest_CL` | PR単位。レビュアーの投票、必須レビュアー数、ブランチポリシー評価、Jira課題キー、自己承認フラグ |
| `ADO_PipelineRun_CL` | Pipeline実行単位。定義リビジョン、実行者、ビルド対象コミット、ステージ結果 |
| `ADO_Approval_CL` | ステージ承認の承認ステップ単位。承認者・承認時刻・コメント・SOD違反フラグ |
| `ADO_ExportAudit_CL` | エクスポート処理自体の記録。抽出／取込件数、生JSONのSHA256ハッシュ |

`ADO_ExportAudit_CL` は「証跡が漏れなく取得されている」ことを証明するためのテーブルです。
監査対応で最も効く証跡なので、月次確認（Q07／Q08）を欠かさないでください。

---

## クイックスタート

```powershell
# 1. 基盤デプロイ
cd infra
.\Deploy-AuditArchive.ps1 `
    -SubscriptionId <サブスクリプションID> `
    -ResourceGroupName <リソースグループ名> `
    -WorkspaceName <Log Analyticsワークスペース名> `
    -IngestionPrincipalObjectId "<サービスプリンシパルのオブジェクトID>"

# 2. 出力された LAW_DCR_ENDPOINT / LAW_DCR_IMMUTABLE_ID / LAW_CUSTOMER_ID を
#    Azure DevOps の変数グループ ado-audit-archive に登録

# 3. オフライン自己テスト（Azure接続不要・任意）
#    モックAPIに対して抽出ロジックを検証します。導入前の確認に利用できます。
cd ..\scripts
.\Invoke-OfflineSmokeTest.ps1

# 4. ローカルでの動作確認（ドライラン）
.\Export-AdoAuditRecords.ps1 `
    -Organization <Azure DevOps組織名> `
    -IngestionEndpoint "<LAW_DCR_ENDPOINT>" `
    -DcrImmutableId "<LAW_DCR_IMMUTABLE_ID>" `
    -WindowStartUtc "2026-09-12T00:00:00Z" `
    -WindowEndUtc "2026-09-19T00:00:00Z" `
    -WhatIfOnly
```

詳細な手順は `docs/02_導入手順書.md` を参照してください。

---

## スケジュール

| スケジュール | cron（UTC） | 実行時刻（JST） | 内容 |
|---|---|---|---|
| 日次増分 | `0 17 * * *` | 翌日 02:00 | 直近24時間＋6時間オーバーラップ |
| 月次フル | `0 18 1 * *` | 毎月2日 03:00 | 前月全体の再スキャン |

重複取込は意図的な設計です。参照時に `RecordId` で重複排除するため、再実行は安全に行えます。

---

## 技術仕様

| 項目 | 内容 |
|---|---|
| PowerShell | 5.1 および 7.x 対応（スクリプトはASCIIのみ・英語メッセージ） |
| 認証（Azure） | ワークロードID連携によるサービスプリンシパル（シークレットなし） |
| 認証（Azure DevOps） | Entra IDサービスプリンシパル（PAT代替も実装済み） |
| 取込API | Logs Ingestion API `api-version=2023-01-01` |
| Azure DevOps API | `api-version=7.1` |
| 1リクエスト上限 | 900KB単位に自動分割（API上限1MB） |
| リトライ | 指数バックオフ最大5回 |
| 概算コスト | 月額 数十〜数百円 |
