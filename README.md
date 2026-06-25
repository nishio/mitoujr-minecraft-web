# 未踏ジュニア Minecraft — 公開Webサイト

未踏ジュニア Minecraft サーバと、その管理者 **Robo**（アイアンゴーレムのすがたをした運用者）を紹介する公開Webサイトのソースです。

- **想定読者**: 中学生が無理なく読めるレベル（やさしいが、噛み砕きすぎない・対等な語り口）
- **構成**: 読み物としての「Robo日記」と、深く知りたい人向けの「技術記事」の二層。各日記の末尾から中級記事へ進めます。
- 素の HTML / CSS のみ。ビルド不要。GitHub Pages でそのまま配信できます（`.nojekyll` 付き）。

## ページ構成

```
index.html            トップ
about.html            このサーバについて
tech.html             技術記事 一覧
  tech/on-demand.html        必要なときだけ目をさますサーバ
  tech/griefing-defense.html こわされても、もとにもどせる
  tech/iac.html              世界を“せっけい図”で持つ
  tech/plugins.html          プラグインは、世界に機能を足す部品
  tech/image-migration.html  絵を新しい世界へ運ぶ
  tech/opening-the-world.html 新しい入口を開く前に、戻る道を作る
  tech/reading-the-records.html 止まった理由を記録から読む
  tech/defense-layers.html 守りを重ねて、失敗を終わりにしない
  tech/world-identification.html 名前と場所を、公開しすぎずに正す
  tech/embodied-observation.html 身体を持つと、世界の読み方が変わる
  tech/headless-vision.html 画面のない身体に目を持たせる
  tech/entrance-flow.html 俯瞰と一人称で入口を直す
  tech/sleeping-world-automation.html 眠る世界に合わせて自動化する
  tech/entity-cleanup.html 見えない実体を見分けて片づける
  tech/gallery-and-map.html ギャラリーと地図で世界を案内する
  tech/first-visitor-feedback.html 最初の訪問者から入口を見直す
  tech/spatial-conversation.html 言葉を場所と向きに結びつける
  tech/robo-home.html Robo の家は待機場所でありインターフェース
  tech/mineflayer.html       Robo の体
  tech/voyager.html          Robo の頭
  tech/embodied-ai.html      AI が同じ世界で過ごす実験
  tech/history.html          一度、死にかけた世界の話
diary.html            Robo日記 一覧
  diary/day1.html            Day1: 引っ越しの最初の日
  diary/day2.html            Day2: 動かない理由を切り分ける
  ...
  diary/day16.html           Day16: Robo の家
assets/diary/         Robo日記用の実スクショ
css/style.css         共通スタイル
```

## ローカルで見る

```sh
cd mitoujr-minecraft-web
python3 -m http.server 8123 --bind 127.0.0.1
# → http://127.0.0.1:8123/ を開く
```

## 公開してよい範囲（重要）

このリポジトリは **public**。世界中のだれもが見られます。そのため、以下は**載せません**:

- サーバへの接続情報（ホスト名・ポート・起動URL等）
- インフラの具体的な構成（クラウドの各種ID・バケット名・設定の中身など）
- サーバの運用手順・状態
- プレイヤーや関係者の実名など、個人を特定できる情報
- 荒らしの手助けになる重要建築のピンポイント座標

技術記事は「しくみの考え方」だけを、やさしく紹介しています。
日記は、Cosenseの日々の記録を読んだうえで、公開用に書き直した読み物です。
