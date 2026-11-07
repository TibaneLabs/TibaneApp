class PortfolioPosition24h {
  final double currentValueUsd;
  final double? percentChange24h;

  const PortfolioPosition24h({
    required this.currentValueUsd,
    required this.percentChange24h,
  });
}

class PortfolioPerformance24h {
  final double amountUsd;
  final double percent;

  const PortfolioPerformance24h({
    required this.amountUsd,
    required this.percent,
  });
}

/// Calculates market movement over the last 24 hours using today's quantities.
/// Deposits and withdrawals are therefore not counted as profit or loss.
/// Returns null instead of presenting a partial result when a valued position
/// has no 24-hour quote.
PortfolioPerformance24h? calculatePortfolioPerformance24h(
  Iterable<PortfolioPosition24h> positions,
) {
  var currentTotal = 0.0;
  var previousTotal = 0.0;
  var hasPosition = false;

  for (final position in positions) {
    final current = position.currentValueUsd;
    if (!current.isFinite || current <= 0) continue;
    final change = position.percentChange24h;
    if (change == null || !change.isFinite || change <= -100) return null;

    hasPosition = true;
    currentTotal += current;
    previousTotal += current / (1 + change / 100);
  }

  if (!hasPosition || previousTotal <= 0 || !previousTotal.isFinite) {
    return null;
  }
  final amount = currentTotal - previousTotal;
  return PortfolioPerformance24h(
    amountUsd: amount,
    percent: amount / previousTotal * 100,
  );
}
