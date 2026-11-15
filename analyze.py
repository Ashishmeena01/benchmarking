
import pandas as pd
import matplotlib.pyplot as plt

# ==========================================
# LOAD CSV
# ==========================================

df = pd.read_csv("results/all-results.csv")

print("\n========== RAW BENCHMARK RESULTS ==========\n")
print(df.to_string(index=False))


# ==========================================
# CALCULATE SUCCESSFUL REQUESTS PER SECOND
# ==========================================

# Successful RPS = total requests/sec * (1 - failure rate)
df["Successful_RPS"] = (
    df["RPS"] * (1 - df["FailedRequest_pct"] / 100)
)

# Group by server and concurrency.
summary = (
    df.groupby(["Concurrency", "Server"])
    .agg(
        Avg_RPS=("RPS", "mean"),
        Successful_RPS=("Successful_RPS", "mean"),
        Avg_Latency=("Avg_ms", "mean"),
        P95_Latency=("P95_ms", "mean"),
        P99_Latency=("P99_ms", "mean"),
        Failed_Percent=("FailedRequest_pct", "mean"),
    )
    .reset_index()
)

print("\n========== COMPARISON ==========\n")

print(
    summary.round(2).to_string(index=False)
)


# ==========================================
# SUCCESSFUL RPS TABLE
# ==========================================

successful_table = summary.pivot(
    index="Concurrency",
    columns="Server",
    values="Successful_RPS"
)

print("\n========== SUCCESSFUL REQUESTS PER SECOND ==========\n")
print(successful_table.round(2).to_string())


# ==========================================
# FIND WINNER AT EACH CONCURRENCY
# ==========================================

print("\n========== WINNER AT EACH CONCURRENCY ==========\n")

for concurrency, group in summary.groupby("Concurrency"):

    winner = group.loc[group["Successful_RPS"].idxmax()]

    print(
        f"{concurrency} VUs -> "
        f"{winner['Server']} "
        f"({winner['Successful_RPS']:.2f} successful RPS)"
    )


# ==========================================
# GRAPH 1: SUCCESSFUL RPS
# ==========================================

successful_table.plot(
    kind="line",
    marker="o",
    figsize=(10, 5)
)

plt.title("Successful Requests Per Second")
plt.xlabel("Virtual Users")
plt.ylabel("Successful RPS")
plt.grid(True)
plt.legend(title="Server")
plt.tight_layout()
plt.savefig("results/successful-rps.png")
plt.show()


# ==========================================
# GRAPH 2: AVERAGE LATENCY
# ==========================================

latency_table = summary.pivot(
    index="Concurrency",
    columns="Server",
    values="Avg_Latency"
)

latency_table.plot(
    kind="line",
    marker="o",
    figsize=(10, 5)
)

plt.title("Average HTTP Latency")
plt.xlabel("Virtual Users")
plt.ylabel("Latency (ms)")
plt.grid(True)
plt.legend(title="Server")
plt.tight_layout()
plt.savefig("results/average-latency.png")
plt.show()


# ==========================================
# GRAPH 3: FAILED REQUESTS
# ==========================================

failure_table = summary.pivot(
    index="Concurrency",
    columns="Server",
    values="Failed_Percent"
)

failure_table.plot(
    kind="line",
    marker="o",
    figsize=(10, 5)
)

plt.title("Failed HTTP Requests")
plt.xlabel("Virtual Users")
plt.ylabel("Failure Rate (%)")
plt.grid(True)
plt.legend(title="Server")
plt.tight_layout()
plt.savefig("results/failure-rate.png")
plt.show()


# ==========================================
# EXPORT ANALYSIS
# ==========================================

summary.to_csv(
    "results/analysis-summary.csv",
    index=False
)

print("\nAnalysis completed!")
print("Graphs saved inside results/")
print("Summary saved as results/analysis-summary.csv")
