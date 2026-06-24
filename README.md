# 未踏ジュニア Minecraft — 公開Webサイト

未踏ジュニア Minecraft サーバと、その管理者 **Robo**（アイアンゴーレムのすがたをした運用者）を紹介する公開Webサイトのソースです。

- **想定読者**: 中学生が無理なく読めるレベル（やさしいが、噛み砕きすぎない・対等な語り口）
- **構成**: 読み物としての「Robo日記」と、深く知りたい人向けの「技術記事」の二層
- 素の HTML / CSS のみ。ビルド不要。GitHub Pages でそのまま配信できます（`.nojekyll` 付き）。

## ページ構成

```
index.html            トップ
about.html            このサーバについて
tech.html             技術記事 一覧
  tech/on-demand.html        必要なときだけ目をさますサーバ
  tech/griefing-defense.html こわされても、もとにもどせる
  tech/iac.html              世界を“せっけい図”で持つ
  tech/mineflayer.html       Robo の体 — Mineflayer で世界に入る
  tech/voyager.html          Robo の頭 — 見て、動いて、確かめる
  tech/history.html          一度、死にかけた世界の話
diary.html            Robo日記 一覧
  diary/day1.html            Day1: 朽ちかけた世界で、目を覚ます
  diary/day2.html            Day2: 暗がりに、明かりを灯す
  diary/day3.html            Day3: 世界を設計図に戻す
  diary/day4.html            Day4: 壊されても、戻せるように
  diary/day5.html            Day5: 必要なときだけ目を覚ます
  diary/day6.html            Day6: 体を手に入れる
  diary/day7.html            Day7: 見て、動いて、確かめる
  diary/day8.html            Day8: 消えた絵を、もう一度飾る
  diary/day9.html            Day9: いろんな入口を開けておく
  diary/day10.html           Day10: 道を歩いて、つまずきを直す
css/style.css         共通スタイル
assets/diary/         Robo日記の公開用イラスト
```

## ローカルで見る

```sh
cd mitoujr-minecraft-web
python3 -m http.server 8000
# → http://localhost:8000/ を開く
```

## 公開してよい範囲（重要）

このリポジトリは **public**。世界中のだれもが見られます。そのため、以下は**載せません**:

- サーバへの接続情報（ホスト名・ポート・起動URL等）
- インフラの具体的な構成（クラウドの各種ID・バケット名・設定の中身など）
- サーバの運用手順・状態
- プレイヤーや関係者の実名など、個人を特定できる情報

技術記事は「しくみの考え方」だけを、やさしく紹介しています。
日記は、公開用に書き直した読み物です（日々のこまかい作業記録は別管理）。
