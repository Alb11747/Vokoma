// Runs at most `maximum` tasks at once; the rest wait in arrival order.
// A finishing task hands its slot straight to the next waiter so new arrivals
// cannot overtake it.
export function concurrencyLimit(maximum: number) {
  let active = 0;
  const waiting: (() => void)[] = [];
  return async <T>(work: () => Promise<T>): Promise<T> => {
    if (active === maximum)
      await new Promise<void>((resolve) => waiting.push(resolve));
    else active++;
    try {
      return await work();
    } finally {
      const next = waiting.shift();
      if (next) next();
      else active--;
    }
  };
}
