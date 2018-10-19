#!/bin/sh

set -ev

Rscript -e "rmarkdown::render_site(output_format = 'bookdown::git_book', encoding = 'UTF-8')"
Rscript -e "rmarkdown::render_site(output_format = 'bookdown::pdf_book', encoding = 'UTF-8')"
Rscript -e "rmarkdown::render_site(output_format = 'bookdown::epub_book', encoding = 'UTF-8')"
