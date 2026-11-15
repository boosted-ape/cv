# boosted-ape.github.io/cv

A [Hugo](https://gohugo.io/) blog using the [paper](https://github.com/nanxiaobei/hugo-paper) theme.

GitHub Pages serves this repository from the `master` branch root, so the
generated site (`index.html`, `posts/`, `tags/`, `*.css`, ...) is committed next
to its source. Hugo is configured with `publishDir: "."` for that reason; do not
run `hugo --cleanDestinationDir`, which would delete the source tree.

## Layout

| Path | Contents |
|---|---|
| `content/posts/` | Articles (Markdown) |
| `assets/custom.css` | Chroma syntax-highlight colors, light + dark |
| `themes/hugo-paper/` | Vendored theme (no submodule) |
| `hugo.yaml` | Site configuration |

## Write

```sh
hugo new posts/my-post.md   # then edit content/posts/my-post.md
hugo server                 # http://localhost:1313/cv/
```

## Build and publish

```sh
./build.sh
git add -A
git commit -m "publish"
git push
```

GitHub Pages picks up the new files on `master` within about a minute.
