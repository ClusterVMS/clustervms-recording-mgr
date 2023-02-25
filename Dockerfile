FROM ruby:3.0.5

	&& rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app
COPY Gemfile* ./
RUN bundle install
COPY . .

EXPOSE 3000
ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT="true"
CMD ["rails", "server", "-b", "0.0.0.0"]
