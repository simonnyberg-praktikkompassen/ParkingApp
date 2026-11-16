#!/bin/sh
# Bygger public/index.html (för Vercel/Netlify) från src/app.html
cd "$(dirname "$0")"
mkdir -p public
{
  printf '<!doctype html>\n<html lang="sv">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n<meta name="theme-color" content="#1d4fb8">\n<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}[hidden]{display:none!important}img{max-width:100%%}</style>\n</head>\n<body>\n'
  cat src/app.html
  printf '\n</body>\n</html>\n'
} > public/index.html
echo "Byggt: public/index.html"
