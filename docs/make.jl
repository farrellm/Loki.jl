using Documenter
using Loki

DocMeta.setdocmeta!(Loki, :DocTestSetup, :(using CausalFrames, Loki); recursive = true)

# The home page IS the README, generated here rather than kept as a second copy
# that would drift. `docs/src/index.md` is generated and gitignored — edit
# README.md. The rewrites separate the GitHub audience from the docs-site one:
# the docs title carries the .jl, the badges are GitHub furniture (one links to
# this very site), and the DESIGN.md link is a repo path that would 404 here.
function readme_as_index(readme, index)
    text = read(readme, String)
    text = replace(text, r"^# Loki\n" => "# Loki.jl\n")
    text = replace(text, r"^\[!\[[^\n]*\n"m => "")
    text = replace(text, r"\n{3,}" => "\n\n")   # the blank run the badges left
    text = replace(
        text,
        "[DESIGN.md](DESIGN.md)" => "[DESIGN.md](https://github.com/farrellm/Loki.jl/blob/master/DESIGN.md)",
    )
    return write(index, text)
end

readme_as_index(
    joinpath(@__DIR__, "..", "README.md"),
    joinpath(@__DIR__, "src", "index.md"),
)

makedocs(;
    modules = [Loki],
    authors = "Matthew Farrell",
    sitename = "Loki.jl",
    format = Documenter.HTML(;
        canonical = "https://farrellm.github.io/Loki.jl",
        edit_link = "master",
        assets = String[],
    ),
    pages = ["Home" => "index.md", "API" => "api.md"],
)

deploydocs(; repo = "github.com/farrellm/Loki.jl", devbranch = "master")
