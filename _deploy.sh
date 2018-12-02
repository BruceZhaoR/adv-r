#!/bin/sh

set -e

[ -z "${GITHUB_PAT}" ] && exit 0
[ "${TRAVIS_BRANCH}" != "master" ] && exit 0

git config --global user.email "brucezhaor2016@gmail.com"
git config --global user.name "BruceZhaoR"

git clone -q -b gh-pages https://${GITHUB_PAT}@github.com/${TRAVIS_REPO_SLUG}.git book-output
cd book-output
git rm -rf *
cp -r ../_book/* ./
git add --all *
git commit -m"Update the book (travis build ${TRAVIS_BUILD_NUMBER})"
# echo add files to gh-pages
git push -q origin gh-pages
