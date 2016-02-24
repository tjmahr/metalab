library(shiny)
library(tidyr)
library(dplyr)
library(ggplot2)
library(pwr)
library(metafor)
library(langcog)
theme_set(theme_mikabr(base_family = "Ubuntu") +
            theme(legend.position = "top",
                  legend.key = element_blank(),
                  legend.background = element_rect(fill = "transparent")))

################################################################################
## CONSTANTS FOR POWER ANALYSIS

pwrmu <- 10
pwrsd <- 5

################################################################################
## HELPER FUNCTIONS

sem <- function(x) {
  sd(x) / sqrt(length(x))
}

ci95.t <- function(x) {
  qt(.975, length(x) - 1) * sem(x)
}

pretty.p <- function(x) {
  as.character(signif(x, digits = 3))
}

shinyServer(function(input, output, session) {

  #############################################################################
  # MODELS AND REACTIVES

  data <- reactive({
    filter(all_data, dataset == input$dataset_name)
  })

  ########### MODEL ###########
  model <- reactive({
    if (length(input$moderators) == 0) {
      no_mod_model()
    } else {
      mods <- paste(input$moderators, collapse = "+")
      rma(as.formula(paste("d_calc ~", mods)), vi = d_var_calc,
          slab = as.character(unique_ID), data = data(), method = "REML")
    }
  })

  ########### NO MODERATORS MODEL ###########
  no_mod_model <- reactive({
    rma(d_calc, vi = d_var_calc, slab = as.character(unique_ID),
        data = data(), method = "REML")
  })

  mod_group <- reactive({
    if (length(input$moderators) == 0) {
      NULL
    } else if ("response_mode" %in% input$moderators &
               "exposure_phase" %in% input$moderators) {
      "response_mode_exposure_phase"
    } else if ("response_mode" %in% input$moderators) {
      "response_mode"
    } else if ("exposure_phase" %in% input$moderators) {
      "exposure_phase"
    }
  })

  output$moderator_input <- renderUI({
    mod_choices <- list("Age" = "mean_age",
                        "Response mode" = "response_mode",
                        "Exposure phase" = "exposure_phase")
    valid_mod_choices <- mod_choices %>% keep(~length(unique(data()[[.x]])) > 1)
    checkboxGroupInput("moderators", label = "Moderators", valid_mod_choices,
                       inline = TRUE)
  })

  output$studies_box <- renderValueBox({
    valueBox(
      nrow(data()), "Studies", icon = icon("list", lib = "glyphicon"),
      color = "red"
    )
  })

  output$effect_size_box <- renderValueBox({
    valueBox(
      sprintf("%.2f", no_mod_model()$b[,1][["intrcpt"]]), "Effect Size",
      icon = icon("record", lib = "glyphicon"),
      color = "red"
    )
  })

  output$effect_size_var_box <- renderValueBox({
    valueBox(
      sprintf("%.2f", no_mod_model()$se[1]), "Effect Size SE",
      icon = icon("resize-horizontal", lib = "glyphicon"),
      color = "red"
    )
  })

  #############################################################################
  # PLOTS

  ########### SCATTER PLOT ###########
  output$scatter <- renderPlot({
    grp <- mod_group()
    if (is.null(grp)) grp <- "all_mod"
    labels <- if (is.null(mod_group())) NULL else
      setNames(paste(data()[[grp]], "  "), data()[[grp]])
    ggplot(data(), aes_string(x = "mean_age_months", y = "d_calc",
                              colour = grp)) +
      geom_jitter(aes(size = n), alpha = 0.5) +
      geom_smooth(method = "lm", se = FALSE) +
      geom_hline(yintercept = 0, linetype = "dashed") +
      scale_colour_solarized(name = "", labels = labels,
                             guide = if (grp == "all_mod") FALSE else "legend") +
      scale_size_continuous(guide = FALSE) +
      xlab("\nMean Subject Age (Months)") +
      ylab("Effect Size\n")
  }, height = function() {
    session$clientData$output_scatter_width * 0.7
  })

  ########### VIOLIN PLOT ###########
  output$violin <- renderPlot({
    grp <- mod_group()
    if (is.null(grp)) grp <- "all_mod"
    # x_label <- switch(
    #   grp,
    #   "all_mod" = "",
    #   "response_mode" = "Response Mode",
    #   "exposure_phase" = "Exposure Phase",
    #   "response_mode_exposure_phase" = "Response Mode and Exposure Phase"
    # )
    ggplot(data(), aes_string(x = grp, y = "d_calc", colour = grp)) +
      geom_jitter(height = 0) +
      geom_violin() +
      geom_hline(yintercept = 0, linetype = "dotted", color = "grey") +
      scale_colour_solarized(name = "", guide = FALSE) +
      xlab("") +
      #xlab(paste0("\n", x_label)) +
      ylab("Effect Size\n")
  })

  ########### FOREST PLOT ###########
  output$forest <- renderPlot({
    f <- fitted(model())
    p <- predict(model())
    alpha <- .05
    forest_data <- data.frame(effects = as.numeric(model()$yi.f),
                              variances = model()$vi.f) %>%
      mutate(effects.cil = effects -
               qnorm(alpha / 2, lower.tail = FALSE) * sqrt(variances),
             effects.cih = effects +
               qnorm(alpha / 2, lower.tail = FALSE) * sqrt(variances),
             estimate = as.numeric(f),
             unique_ID = names(f),
             estimate.cil = p$ci.lb,
             estimate.cih = p$ci.ub,
             identity = 1) %>%
      left_join(mutate(data(), unique_ID = make.unique(unique_ID))) %>%
      arrange(desc(effects)) %>%
      mutate(unique_ID = factor(unique_ID, levels = unique_ID))

    qplot(unique_ID, effects, ymin = effects.cil, ymax = effects.cih,
          geom = "linerange",
          data = forest_data) +
      geom_point(aes(y = effects, size = n)) +
      geom_pointrange(aes(x = unique_ID,
                          y = estimate,
                          ymin = estimate.cil,
                          ymax = estimate.cih),
                      col = "red") +
      coord_flip() +
      scale_size_continuous(guide = FALSE) + #name = "N") +
      scale_colour_manual(values = c("data" = "black", "model" = "red")) +
      xlab("") +
      ylab("Effect Size")
  }, height = function() {
    session$clientData$output_forest_width * 2
  })

  ########### FUNNEL PLOT ###########
  output$funnel <- renderPlot({
    if (length(input$moderators) == 0) {
      d <- data.frame(se = sqrt(model()$vi), es = model()$yi)
      center <- mean(d$es)
      xlabel <- "\nEffect Size"
    } else {
      r <- rstandard(model())
      d <- data.frame(se = r$se, es = r$resid)
      center <- 0
      xlabel <- "\nResidual"
    }

    lower_lim <- max(d$se) + .05 * max(d$se)
    left_lim <- ifelse(center - lower_lim * 1.96 < min(d$es),
                       center - lower_lim * 1.96,
                       min(d$es))
    right_lim <- ifelse(center + lower_lim * 1.96 > max(d$es),
                        center + lower_lim * 1.96,
                        max(d$es))
    funnel <- data.frame(x = c(center - lower_lim * 1.96, center,
                               center + lower_lim * 1.96),
                         y = c(-lower_lim, 0, -lower_lim))

    ggplot(d, aes(x = es, y = -se)) +
      scale_x_continuous(limits = c(left_lim,right_lim)) +
      scale_y_continuous(expand = c(0, 0),
                         breaks = round(seq(0, -max(d$se), length.out = 5), 2),
                         labels = round(seq(0, max(d$se), length.out = 5), 2)) +
      geom_polygon(data = funnel, aes(x = x, y = y), fill = "white") +
      geom_vline(xintercept = center, linetype = "dotted", color = "black",
                 size = .5) +
      geom_point() +
      xlab(xlabel) +
      ylab("Standard error\n") +
      theme(panel.background = element_rect(fill = "grey"),
            panel.grid.major =  element_line(colour = "darkgrey", size = 0.2),
            panel.grid.minor =  element_line(colour = "darkgrey", size = 0.5))


  }, height = function() {
    session$clientData$output_funnel_width * 0.7
  })

  #############################################################################
  # POWER ANALYSIS

  conds <- reactive({
    if (input$control) {
      groups <- factor(c("Experimental","Control",
                         levels = c("Experimental", "Control")))
    } else {
      groups <- factor("Experimental")
    }
    expand.grid(group = groups,
                condition = factor(c("Longer looking predicted",
                                     "Shorter looking predicted"))) %>%
      group_by(group, condition)
  })

  ########### GENERATE DATA #############
  pwrdata <- reactive({
    if (input$go | !input$go) {
      conds() %>%
        do(data.frame(
          looking.time = ifelse(
            rep(.$group == "Experimental" &
                  .$condition == "Longer looking predicted", input$N),
            rnorm(n = input$N,
                  mean = pwrmu + (input$d * pwrsd) / 2,
                  sd = pwrsd),
            rnorm(n = input$N,
                  mean = pwrmu - (input$d * pwrsd) / 2,
                  sd = pwrsd)
          )
        )
        )
    }
  })

  ########### MEANS FOR PLOTTING #############
  ms <- reactive({
    pwrdata() %>%
      group_by(group, condition) %>%
      summarise(mean = mean(looking.time),
                ci = ci95.t(looking.time),
                sem = sem(looking.time)) %>%
      rename_("interval" = input$interval)
  })

  ########### BAR GRAPH #############
  output$bar <- renderPlot({
    pos <- position_dodge(width = .25)
    ggplot(ms(), aes(x = group, y = mean, fill = condition,
                     colour = condition)) +
      geom_bar(position = pos,
               stat = "identity",
               width = .25) +
      geom_linerange(data = ms(),
                     aes(x = group, y = mean,
                         fill = condition,
                         ymin = mean - interval,
                         ymax = mean + interval),
                     position = pos,
                     colour = "black") +
      xlab("Group") +
      ylab("Simulated Looking Time") +
      scale_fill_solarized(name = "",
                           labels = setNames(paste(ms()$condition, "  "),
                                             ms()$condition)) +
      scale_colour_solarized(name = "",
                             labels = setNames(paste(ms()$condition, "  "),
                                               ms()$condition))
  })

  ########### SCATTER PLOT #############
  #   output$scatter <- renderPlot({
  #     print(ms())
  #     print(data())
  #     pos <- position_jitterdodge(jitter.width = .1,
  #                                 dodge.width = .25)
  #     qplot(group, looking.time, fill = condition,
  #           colour = condition,
  #           group = condition,
  #           position = pos,
  #           geom="point",
  #           data = data()) +
  #       geom_linerange(data = ms(),
  #                      aes(x = group, y = mean,
  #                          fill = condition,
  #                          ymin = mean - interval,
  #                          ymax = mean + interval),
  #                      position = pos,
  #                      size = 2,
  #                      colour = "black") +
  #       xlab("Group") +
  #       ylab("Looking Time") +
  #       ylim(c(0, ceiling(max(data()$looking.time)/5)*5))
  #   })
  #

  ########### STATISTICAL TEST OUTPUTS #############
  output$stat <- renderText({
    p.e <- t.test(
      pwrdata() %>%
        filter(condition == "Longer looking predicted",
               group == "Experimental") %>%
        select(looking.time),
      pwrdata() %>%
        filter(condition == "Shorter looking predicted",
               group == "Experimental") %>%
        select(looking.time),
      paired = TRUE
    )$p.value

    stat.text <- paste("A t.test of the experimental condition is ",
                       ifelse(p.e > .05, "non", ""),
                       "significant at p = ",
                       pretty.p(p.e),
                       ". ",
                       sep = "")

    if (input$control) {
      p.c <- t.test(
        pwrdata() %>%
          filter(condition == "Longer looking predicted",
                 group == "Control") %>%
          select(looking.time),
        pwrdata() %>%
          filter(condition == "Shorter looking predicted",
                 group == "Control") %>%
          select(looking.time),
        paired = TRUE
      )$p.value

      a <- anova(lm(looking.time ~ group * condition, data = pwrdata()))

      return(paste(stat.text,
                   "A t.test of the control condition is ",
                   ifelse(p.c > .05, "non", ""),
                   "significant at p = ",
                   pretty.p(p.c),
                   ". An ANOVA ",
                   ifelse(a$"Pr(>F)"[3] < .05,
                          "shows a", "does not show a"),
                   " significant interaction at p = ",
                   pretty.p(a$"Pr(>F)"[3]),
                   ".",
                   sep = ""))
    }

    return(stat.text)
  })

  ########### POWER COMPUTATIONS #############
  output$power <- renderPlot({
    if (input$control) {
      ns <- seq(5, 120, 5)
      pwrs <- data.frame(ns = ns,
                         Experimental = pwr.p.test(h = input$d,
                                                   n = ns,
                                                   sig.level = .05)$power,
                         Control = pwr.p.test(h = 0,
                                              n = ns,
                                              sig.level = .05)$power,
                         Interaction = pwr.2p.test(h = input$d,
                                                   n = ns,
                                                   sig.level = .05)$power) %>%
        gather(condition, ps, Experimental, Interaction, Control)


      this.pwr <- data.frame(ns = rep(input$N, 3),
                             ps = c(pwr.p.test(h = input$d,
                                               n = input$N,
                                               sig.level = .05)$power,
                                    pwr.p.test(h = 0,
                                               n = input$N,
                                               sig.level = .05)$power,
                                    pwr.2p.test(h = input$d,
                                                n = input$N,
                                                sig.level = .05)$power),
                             condition = c("Experimental", "Interaction",
                                           "Control"))
      qplot(ns, ps, col = condition,
            geom = c("point","line"),
            data = pwrs) +
        geom_point(data = this.pwr,
                   col = "red", size = 6) +
        geom_hline(yintercept = .8, lty = 2) +
        geom_vline(xintercept = pwr.p.test(h = input$d,
                                           sig.level = .05,
                                           power = .8)$n, lty = 2) +
        geom_vline(xintercept = pwr.2p.test(h = input$d,
                                            sig.level = .05,
                                            power = .8)$n, lty = 2) +
        ylim(c(0,1)) +
        ylab("Power to reject the null at p < .05") +
        xlab("Number of participants (N)") +
        scale_colour_solarized(name = "",
                               labels = setNames(paste(pwrs$condition, "  "),
                                                 pwrs$condition))

    } else {
      ns <- seq(5, 120, 5)
      pwrs <- data.frame(ns = ns,
                         ps = pwr.p.test(h = input$d,
                                         n = ns,
                                         sig.level = .05)$power)

      this.pwr <- data.frame(ns = input$N,
                             ps = pwr.p.test(h = input$d,
                                             n = input$N,
                                             sig.level = .05)$power)
      qplot(ns, ps, geom = c("point","line"),
            data = pwrs) +
        geom_point(data = this.pwr,
                   col = "red", size = 6) +
        geom_hline(yintercept = .8, lty = 2) +
        geom_vline(xintercept = pwr.p.test(h = input$d,
                                           sig.level = .05,
                                           power = .8)$n, lty = 2) +
        ylim(c(0,1)) +
        ylab("Power to reject the null at p < .05") +
        xlab("Number of participants (N)")
    }
  })

})