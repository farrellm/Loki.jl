# The Loki session the browser tests drive. Seeded, so every run builds the same
# graph from the same numbers and a spec that depends on a value is not flaky.
using CausalFrames, DataFrames, Loki, Random

const PORT = parse(Int, get(ENV, "LOKI_TEST_PORT", "8713"))
const TOKEN = get(ENV, "LOKI_TEST_TOKEN", "playwright-token")

rng = Xoshiro(20260916)
y = zeros(400)
for t in 2:400
    y[t] = 0.7 * y[t-1] + randn(rng)
end
prices = DataFrame(time = 1:400, close = 100 .+ cumsum(y) ./ 5)

session = Loki.Session(; tables = (prices = prices,),
    contexts = (analysis = Context(0, 401), train = Context(0, 201)))
Loki.serve(session; port = PORT, token = TOKEN, open_browser = false)

# A source to start from: every spec builds the rest itself, so each one can see
# the graph change under it.
Loki.addnode!(session, "table", Dict("table" => "prices"); position = (60, 60))

println("Loki test server ready on http://127.0.0.1:$PORT/#token=$TOKEN")
flush(stdout)
while true
    sleep(3600)
end
