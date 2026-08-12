# Real optional-adapter smoke

Run the explicit integration gate from the repository root:

```sh
make test-integration-adapters
```

The smoke loads these exact revisions:

- Telescope `427b576c16792edad01a92b89721d923c19ad60f`
- Plenary `74b06c6c75e4eeb3108ec01852001636d85a932b`
- Overseer `a93d9f6d6defdac4bcd6d2c8ba988650e42e0a0e`

Clean matching checkouts from the normal Neovim package directory are reused.
Otherwise the script fetches each exact commit into a disposable directory. It
drives one real Telescope selection and runs `nvim --version` through the real
Overseer task lifecycle. Exhaustive cancellation and malformed-adapter behavior
remain in the fast fake-based contracts.
