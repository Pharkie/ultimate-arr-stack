/**
 * A simple named-queue implementation that prevents duplicate concurrent
 * requests for the same resource key.
 *
 * If a request for key K is already in-flight, subsequent callers wait for it
 * and receive the same resolved value (fan-out deduplication).
 */
export default class NamedQueue {
  constructor(concurrency = 200) {
    this._concurrency = concurrency;
    this._inFlight    = new Map();  // key → Promise
    this._running     = 0;
    this._waiting     = [];
  }

  /**
   * Wrap an async worker function with named deduplication.
   *
   * @param {{ id: string }} options
   * @param {Function}       worker   (done: () => void) => void
   */
  wrap({ id }, worker) {
    if (this._inFlight.has(id)) {
      return this._inFlight.get(id);
    }

    const promise = this._enqueue(worker);
    this._inFlight.set(id, promise);
    promise.finally(() => this._inFlight.delete(id));
    return promise;
  }

  _enqueue(worker) {
    return new Promise((resolve, reject) => {
      const task = () => {
        this._running++;
        let finished = false;
        const done = () => {
          if (finished) return;
          finished = true;
          this._running--;
          this._dequeue();
        };

        // Worker calls done() when complete; we wrap in a try-catch
        try {
          const result = worker(done);
          if (result && typeof result.then === 'function') {
            result.then(resolve, reject).finally(done);
          } else {
            resolve(result);
            done();
          }
        } catch (err) {
          reject(err);
          done();
        }
      };

      if (this._running < this._concurrency) {
        task();
      } else {
        this._waiting.push(task);
      }
    });
  }

  _dequeue() {
    if (this._waiting.length && this._running < this._concurrency) {
      const next = this._waiting.shift();
      next();
    }
  }
}
