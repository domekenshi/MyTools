# new-repo

ローカルフォルダを GitHub リポジトリに1コマンドで紐づけるシェルスクリプト。
リポジトリ名・公開設定を対話形式で入力するだけで、`git init` から `push` まで自動で完了する。

## 必要なもの

- macOS（zsh）
- [Homebrew](https://brew.sh)
- GitHub CLI（`gh`）

## セットアップ

```bash
# 1. GitHub CLI をインストール
brew install gh

# 2. GitHub にログイン
gh auth login

# 3. スクリプトを配置して実行権限を付与
mkdir -p ~/bin
cp new-repo ~/bin/new-repo
chmod +x ~/bin/new-repo

# 4. PATH に追加（.zshrc に追記）
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## 使い方

新しいフォルダで作業を始めたら実行するだけ。

```bash
cd ~/your-project
new-repo
```

```
リポジトリ名 [your-project]:         ← Enter でフォルダ名をそのまま使用
公開設定: 1) public  2) private [2]: ← 1 か 2 を入力
```

あとは自動で以下を実行する。

1. `git init`
2. デフォルトブランチを `main` に設定
3. `git add .` / `git commit`
4. GitHub にリポジトリを作成
5. `git push`

完了後に GitHub の URL が表示される。

## 動作確認環境

| 項目  | バージョン |
| ----- | ---------- |
| macOS | Sequoia 15 |
| Git   | 2.51.0     |
| gh    | 2.94.0     |
