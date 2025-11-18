defmodule Eureka.Backoff do
  @moduledoc """
  Generic backoff utilities for retrying operations with exponential backoff.
  """

  @doc """
  Executes a function with exponential backoff retry logic.

  ## Parameters
  - fun: The function to execute (should return {:ok, result} or {:error, reason})
  - max_attempts: Maximum number of attempts (default: 4)
  - base_delay: Base delay in milliseconds (default: 1000)
  - backoff_multiplier: Multiplier for exponential backoff (default: 2)

  ## Returns
  - {:ok, result} if the function succeeds
  - {:error, reason} if all attempts fail

  ## Examples
      iex> Eureka.Backoff.with_retry(fn -> {:ok, "success"} end)
      {:ok, "success"}

      iex> Eureka.Backoff.with_retry(fn -> {:error, :fail} end, 3)
      {:error, :fail}
  """
  def with_retry(fun, max_attempts \\ 4, base_delay \\ 1000, backoff_multiplier \\ 2) do
    do_with_retry(fun, max_attempts, base_delay, backoff_multiplier, 1)
  end

  @doc """
  Executes a function with exponential backoff, but only retries for specific error conditions.

  ## Parameters
  - fun: The function to execute (should return {:ok, result} or {:error, reason})
  - should_retry?: Function that takes an error reason and returns true if should retry
  - max_attempts: Maximum number of attempts (default: 4)
  - base_delay: Base delay in milliseconds (default: 1000)
  - backoff_multiplier: Multiplier for exponential backoff (default: 2)

  ## Returns
  - {:ok, result} if the function succeeds
  - {:error, reason} if all attempts fail or error doesn't match retry condition

  ## Examples
      iex> should_retry = fn {:network_error, _} -> true; _ -> false end
      iex> Eureka.Backoff.with_retry_conditional(fn -> {:error, :other} end, should_retry)
      {:error, :other}
  """
  def with_retry_conditional(
        fun,
        should_retry?,
        max_attempts \\ 4,
        base_delay \\ 1000,
        backoff_multiplier \\ 2
      ) do
    do_with_retry_conditional(fun, should_retry?, max_attempts, base_delay, backoff_multiplier, 1)
  end

  # Private implementation

  defp do_with_retry(fun, max_attempts, _base_delay, _backoff_multiplier, attempt)
       when attempt > max_attempts do
    # Final attempt, no more retries
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_with_retry(fun, max_attempts, base_delay, backoff_multiplier, attempt) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if attempt < max_attempts do
          delay = calculate_delay(base_delay, backoff_multiplier, attempt - 1)
          :timer.sleep(delay)
          do_with_retry(fun, max_attempts, base_delay, backoff_multiplier, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp do_with_retry_conditional(
         fun,
         _should_retry?,
         max_attempts,
         _base_delay,
         _backoff_multiplier,
         attempt
       )
       when attempt > max_attempts do
    # Final attempt, no more retries
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_with_retry_conditional(
         fun,
         should_retry?,
         max_attempts,
         base_delay,
         backoff_multiplier,
         attempt
       ) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if attempt < max_attempts and should_retry?.(reason) do
          delay = calculate_delay(base_delay, backoff_multiplier, attempt - 1)
          :timer.sleep(delay)

          do_with_retry_conditional(
            fun,
            should_retry?,
            max_attempts,
            base_delay,
            backoff_multiplier,
            attempt + 1
          )
        else
          {:error, reason}
        end
    end
  end

  defp calculate_delay(base_delay, multiplier, attempt_index) do
    trunc(base_delay * :math.pow(multiplier, attempt_index))
  end
end
