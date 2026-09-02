module ApplicationHelper
  # The wrapper class for one form field, marked invalid when that attribute has errors.
  def field_class(record, attribute)
    class_names("form__field", "form__field--invalid" => record.errors.include?(attribute))
  end

  # The error messages for one attribute, in an element the input points at with
  # aria-describedby. Returns nil when the attribute is valid, so the markup stays quiet.
  def field_error(record, attribute)
    messages = record.errors.full_messages_for(attribute)
    return if messages.empty?

    tag.span messages.to_sentence, class: "form__error", id: field_error_id(record, attribute)
  end

  def field_error_id(record, attribute)
    "#{record.model_name.param_key}_#{attribute}_error"
  end

  # aria attributes for an input whose attribute may be invalid.
  def field_aria(record, attribute)
    return {} unless record.errors.include?(attribute)

    { invalid: true, describedby: field_error_id(record, attribute) }
  end
end
