defmodule Swoosh.Adapters.Mailgun do
  @moduledoc ~S"""
  An adapter that sends email using the Mailgun API.

  For reference: [Mailgun API docs](https://documentation.mailgun.com/api-sending.html#sending)

  ## Example

      # config/config.exs
      config :sample, Sample.Mailer,
        adapter: Swoosh.Adapters.Mailgun,
        api_key: "my-api-key",
        domain: "avengers.com"

      # lib/sample/mailer.ex
      defmodule Sample.Mailer do
        use Swoosh.Mailer, otp_app: :sample
      end
  """

  use Swoosh.Adapter, required_config: [:api_key, :domain]

  alias HTTPoison.Response
  alias Swoosh.Email

  @base_url     "https://api.mailgun.net/v3"
  @api_endpoint "/messages"

  def deliver(%Email{} = email, config \\ []) do
    url = base_url(config) <> "/" <> config[:domain] <> @api_endpoint
    headers = prepare_headers(email, config)
    body = prepare_message(email) |> prepare_body

    case HTTPoison.post(url, body, headers) do
      {:ok, %Response{status_code: code, body: body}} when code >= 200 and code <= 299 ->
        {:ok, %{id: Poison.decode!(body)["id"]}}
      {:ok, %Response{status_code: code, body: body}} when code == 401 ->
        {:error, body}
      {:ok, %Response{status_code: code, body: body}} when code >= 400 and code <= 499 ->
        {:error, Poison.decode!(body)}
      {:ok, %Response{status_code: code, body: body}} when code >= 500 and code <= 599 ->
        {:error, Poison.decode!(body)}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp base_url(config), do: config[:base_url] || @base_url

  defp prepare_headers(email, config) do
    [{"User-Agent", "swoosh/#{Swoosh.version}"},
     {"Authorization", "Basic #{auth(config)}"},
     {"Content-Type", content_type(email)}]
  end

  defp auth(config), do: Base.encode64("api:#{config[:api_key]}")

  defp content_type(%Email{attachments: nil}), do: "application/x-www-form-urlencoded"
  defp content_type(%Email{attachments: []}), do: "application/x-www-form-urlencoded"
  defp content_type(%Email{}), do: "multipart/form-data"

  defp prepare_message(email) do
    %{}
    |> prepare_from(email)
    |> prepare_to(email)
    |> prepare_subject(email)
    |> prepare_html(email)
    |> prepare_text(email)
    |> prepare_cc(email)
    |> prepare_bcc(email)
    |> prepare_reply_to(email)
    |> prepare_attachments(email)
  end

  defp prepare_from(body, %Email{from: from}), do: Map.put(body, :from, prepare_recipient(from))

  defp prepare_to(body, %Email{to: to}), do: Map.put(body, :to, prepare_recipients(to))

  defp prepare_reply_to(body, %Email{reply_to: nil}), do: body
  defp prepare_reply_to(body, %Email{reply_to: {_name, address}}), do: Map.put(body, "h:Reply-To", address)

  defp prepare_cc(body, %Email{cc: []}), do: body
  defp prepare_cc(body, %Email{cc: cc}), do: Map.put(body, :cc, prepare_recipients(cc))

  defp prepare_bcc(body, %Email{bcc: []}), do: body
  defp prepare_bcc(body, %Email{bcc: bcc}), do: Map.put(body, :bcc, prepare_recipients(bcc))

  defp prepare_recipients(recipients) do
    recipients
    |> Enum.map(&prepare_recipient(&1))
    |> Enum.join(",")
  end

  defp prepare_recipient({"", address}), do: address
  defp prepare_recipient({name, address}), do: "#{name} <#{address}>"

  defp prepare_subject(body, %Email{subject: subject}), do: Map.put(body, :subject, subject)

  defp prepare_text(body, %{text_body: nil}), do: body
  defp prepare_text(body, %{text_body: text_body}), do: Map.put(body, :text, text_body)

  defp prepare_html(body, %{html_body: nil}), do: body
  defp prepare_html(body, %{html_body: html_body}), do: Map.put(body, :html, html_body)

  defp prepare_attachments(body, %Email{attachments: nil}), do: body
  defp prepare_attachments(body, %Email{attachments: []}), do: body
  defp prepare_attachments(body, %Email{attachments: attachments}), do: Map.put(body, :attachments, attachments)

  defp prepare_body(%{attachments: _} = message),
    do: {:multipart, prepare_field_parts(message) ++ prepare_attachment_parts(message)}
  defp prepare_body(message),
    do: Plug.Conn.Query.encode(message)

  defp prepare_field_parts(message) do
    message
    |> Map.delete(:attachments)
    |> Enum.map(&prepare_field_part/1)
  end

  defp prepare_field_part({field, content}) when is_atom(field),
    do: {Atom.to_string(field), content}
  defp prepare_field_part({field, content}),
    do: {field, content}

  defp prepare_attachment_parts(%{attachments: attachments}),
    do: Enum.map(attachments, &prepare_attachment_part/1)

  defp prepare_attachment_part(%{filename: filename, path: path}) do
    {:file, path, attachment_disposition(filename), []}
  end
  defp prepare_attachment_part(%{filename: filename, content: content, content_type: content_type}) do
    extra_headers = [{"Content-Type", content_type}]
    {"file", content, attachment_disposition(filename), extra_headers}
  end

  defp attachment_disposition(filename) do
    {"form-data", [{"name", "\"attachment\""}, {"filename", "\"#{filename}\""}]}
  end
end
